/* Streaming subprocesses use their own handle, leaving blocking hl_process APIs intact. */
#ifdef HL_WIN
#include <windows.h>
#include <wchar.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pthread.h>
extern char **environ;
#endif

typedef struct realtime_child_process {
	void (*finalize)(void *);
#ifdef HL_WIN
	HANDLE stdin_pipe, stdout_pipe, stderr_pipe;
	HANDLE writer_thread;
	HANDLE process, job;
	DWORD pid, exit_status;
	CRITICAL_SECTION write_mutex;
	unsigned char *write_queue;
	size_t write_length, write_inflight, write_capacity;
	bool write_close_requested, write_failed, write_mutex_ready;
#else
	int stdin_fd, stdout_fd, stderr_fd;
	int pid, exit_status;
	int process_group;
	bool owns_process_group;
#endif
	bool closed, exited, detached;
} realtime_child_process;

#ifdef HL_WIN
static wchar_t *realtime_child_wide(vstring *value) {
	char *utf8 = realtime_utf8_copy(value);
	int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
	if (length <= 0) { free(utf8); return NULL; }
	wchar_t *result = malloc((size_t)length * sizeof(wchar_t));
	if (result == NULL || MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, result, length) != length) {
		free(utf8); free(result); return NULL;
	}
	free(utf8);
	return result;
}

static size_t realtime_child_quote_size(const wchar_t *value) {
	size_t size = 2, slashes = 0;
	for (const wchar_t *at = value; ; at++) {
		if (*at == L'\\') { slashes++; continue; }
		if (*at == L'"') size += slashes * 2 + 2;
		else if (*at == 0) { size += slashes * 2; break; }
		else size += slashes + 1;
		slashes = 0;
	}
	return size;
}

static wchar_t *realtime_child_quote(wchar_t *out, const wchar_t *value) {
	*out++ = L'"';
	size_t slashes = 0;
	for (const wchar_t *at = value; ; at++) {
		if (*at == L'\\') { slashes++; continue; }
		if (*at == L'"') {
			for (size_t i = 0; i < slashes * 2 + 1; i++) *out++ = L'\\';
			*out++ = L'"';
		} else if (*at == 0) {
			for (size_t i = 0; i < slashes * 2; i++) *out++ = L'\\';
			break;
		} else {
			for (size_t i = 0; i < slashes; i++) *out++ = L'\\';
			*out++ = *at;
		}
		slashes = 0;
	}
	*out++ = L'"';
	return out;
}

static int realtime_child_poll(realtime_child_process *p, bool wait) {
	if (!p->exited) {
		DWORD result = WaitForSingleObject(p->process, wait ? INFINITE : 0);
		if (result == WAIT_OBJECT_0) {
			if (!GetExitCodeProcess(p->process, &p->exit_status)) hl_error("Could not read child process status");
			p->exited = true;
		} else if (result == WAIT_FAILED) hl_error("Could not wait for child process");
	}
	return p->exited ? (int)p->exit_status : -1;
}

static void realtime_child_handle_close(HANDLE *handle) {
	if (*handle != NULL && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
	*handle = NULL;
}

static void realtime_child_cleanup(void *value) {
	realtime_child_process *p = value;
	if (p->closed) return;
	if (p->job != NULL) TerminateJobObject(p->job, 1);
	else if (!p->detached && !p->exited) TerminateProcess(p->process, 1);
	if (!p->exited && !p->detached) (void)realtime_child_poll(p, true);
	if (p->write_mutex_ready) {
		EnterCriticalSection(&p->write_mutex);
		p->write_close_requested = true;
		LeaveCriticalSection(&p->write_mutex);
	}
	if (p->writer_thread != NULL) {
		WaitForSingleObject(p->writer_thread, INFINITE);
		realtime_child_handle_close(&p->writer_thread);
	}
	realtime_child_handle_close(&p->stdin_pipe);
	realtime_child_handle_close(&p->stdout_pipe);
	realtime_child_handle_close(&p->stderr_pipe);
	realtime_child_handle_close(&p->process);
	/* Closing a kill-on-close job retires descendants even if the launcher exited first. */
	realtime_child_handle_close(&p->job);
	if (p->write_mutex_ready) DeleteCriticalSection(&p->write_mutex);
	free(p->write_queue);
	p->closed = true;
}

static DWORD WINAPI realtime_child_writer(void *value) {
	realtime_child_process *p = value;
	unsigned char buffer[16384];
	for (;;) {
		EnterCriticalSection(&p->write_mutex);
		size_t amount = p->write_length < sizeof(buffer) ? p->write_length : sizeof(buffer);
		if (amount != 0) {
			memcpy(buffer, p->write_queue, amount);
			memmove(p->write_queue, p->write_queue + amount, p->write_length - amount);
			p->write_length -= amount;
			p->write_inflight += amount;
			LeaveCriticalSection(&p->write_mutex);
			DWORD offset = 0;
			while (offset < amount) {
				DWORD written = 0;
				if (!WriteFile(p->stdin_pipe, buffer + offset, (DWORD)(amount - offset), &written, NULL) || written == 0) {
					EnterCriticalSection(&p->write_mutex);
					p->write_failed = true; p->write_inflight -= amount;
					realtime_child_handle_close(&p->stdin_pipe);
					LeaveCriticalSection(&p->write_mutex);
					return 0;
				}
				offset += written;
			}
			EnterCriticalSection(&p->write_mutex);
			p->write_inflight -= amount;
			LeaveCriticalSection(&p->write_mutex);
			continue;
		}
		bool stop = p->write_close_requested;
		LeaveCriticalSection(&p->write_mutex);
		if (stop) {
			realtime_child_handle_close(&p->stdin_pipe);
			return 0;
		}
		Sleep(2);
	}
}

static bool realtime_child_make_pipe(HANDLE *read_end, HANDLE *write_end) {
	SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
	if (!CreatePipe(read_end, write_end, &attributes, 0)) return false;
	return true;
}

static void realtime_child_free_environment(wchar_t **entries, int count, wchar_t *block) {
	if (entries != NULL) {
		for (int i = 0; i < count; i++) free(entries[i]);
		free(entries);
	}
	free(block);
}

static int realtime_child_environment_compare(const void *left, const void *right) {
	const wchar_t *const *left_entry = left;
	const wchar_t *const *right_entry = right;
	return _wcsicmp(*left_entry, *right_entry);
}

static wchar_t *realtime_child_environment(varray *keys, varray *values) {
	int overrides = keys == NULL ? 0 : keys->size;
	if (overrides != (values == NULL ? 0 : values->size)) return NULL;
	if (overrides == 0) return NULL;
	wchar_t **entries = NULL, *block = NULL;
	int count = 0, capacity = 0;
	LPWCH inherited = GetEnvironmentStringsW();
	if (inherited == NULL) return NULL;
	for (const wchar_t *at = inherited; *at != 0; at += wcslen(at) + 1) {
		if (count == capacity) {
			int next = capacity == 0 ? 32 : capacity * 2;
			wchar_t **grown = realloc(entries, (size_t)next * sizeof(wchar_t *));
			if (grown == NULL) { FreeEnvironmentStringsW(inherited); realtime_child_free_environment(entries, count, NULL); return NULL; }
			entries = grown; capacity = next;
		}
		size_t length = wcslen(at) + 1;
		entries[count] = malloc(length * sizeof(wchar_t));
		if (entries[count] == NULL) { FreeEnvironmentStringsW(inherited); realtime_child_free_environment(entries, count, NULL); return NULL; }
		memcpy(entries[count++], at, length * sizeof(wchar_t));
	}
	FreeEnvironmentStringsW(inherited);
	for (int index = 0; index < overrides; index++) {
		wchar_t *key = realtime_child_wide(hl_aptr(keys, vstring *)[index]);
		wchar_t *value = realtime_child_wide(hl_aptr(values, vstring *)[index]);
		if (key == NULL || value == NULL || key[0] == 0 || wcschr(key, L'=') != NULL) {
			free(key); free(value); realtime_child_free_environment(entries, count, NULL); return NULL;
		}
		size_t key_length = wcslen(key), value_length = wcslen(value);
		wchar_t *entry = malloc((key_length + value_length + 2) * sizeof(wchar_t));
		if (entry == NULL) { free(key); free(value); realtime_child_free_environment(entries, count, NULL); return NULL; }
		memcpy(entry, key, key_length * sizeof(wchar_t)); entry[key_length] = L'=';
		memcpy(entry + key_length + 1, value, (value_length + 1) * sizeof(wchar_t));
		int slot = 0;
		while (slot < count) {
			const wchar_t *separator = wcschr(entries[slot], L'=');
			if (separator != NULL && (size_t)(separator - entries[slot]) == key_length &&
				_wcsnicmp(entries[slot], key, key_length) == 0) break;
			slot++;
		}
		if (slot == count) {
			if (count == capacity) {
				int next = capacity == 0 ? 32 : capacity * 2;
				wchar_t **grown = realloc(entries, (size_t)next * sizeof(wchar_t *));
				if (grown == NULL) { free(entry); free(key); free(value); realtime_child_free_environment(entries, count, NULL); return NULL; }
				entries = grown; capacity = next;
			}
			count++;
		} else free(entries[slot]);
		entries[slot] = entry;
		free(key); free(value);
	}
	qsort(entries, (size_t)count, sizeof(*entries), realtime_child_environment_compare);
	size_t total = 1;
	for (int i = 0; i < count; i++) total += wcslen(entries[i]) + 1;
	block = calloc(total + 1, sizeof(wchar_t));
	if (block == NULL) { realtime_child_free_environment(entries, count, NULL); return NULL; }
	wchar_t *cursor = block;
	for (int i = 0; i < count; i++) {
		size_t length = wcslen(entries[i]) + 1;
		memcpy(cursor, entries[i], length * sizeof(wchar_t)); cursor += length;
	}
	*cursor = 0;
	realtime_child_free_environment(entries, count, NULL);
	return block;
}
#else
static int realtime_child_poll(realtime_child_process *p, bool wait) {
	if (!p->exited) {
		int status;
		pid_t result;
		do { result = waitpid(p->pid, &status, wait ? 0 : WNOHANG); } while (result < 0 && errno == EINTR);
		if (result == p->pid) {
			p->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
			p->exited = true;
		} else if (result < 0) hl_error("Could not reap child process");
	}
	return p->exited ? p->exit_status : -1;
}
static void realtime_child_fd_close(int *fd) {
	if (*fd >= 0) close(*fd);
	*fd = -1;
}
static void realtime_child_cleanup(void *value) {
	realtime_child_process *p = value;
	if (p->closed) return;
	/* Explicit ownership: close never leaves a live child or zombie behind. */
	if (!p->exited) {
		int status;
		pid_t result;
		do { result = waitpid(p->pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
		if (result == 0 && !p->detached) {
			if (p->owns_process_group) (void)kill(-p->process_group, SIGKILL);
			else (void)kill(p->pid, SIGKILL);
			do { result = waitpid(p->pid, &status, 0); } while (result < 0 && errno == EINTR);
		}
		if (result == p->pid) {
			p->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
			p->exited = true;
		}
	}
	if (!p->detached && p->owns_process_group) (void)kill(-p->process_group, SIGKILL);
	realtime_child_fd_close(&p->stdin_fd);
	realtime_child_fd_close(&p->stdout_fd);
	realtime_child_fd_close(&p->stderr_fd);
	p->closed = true;
}
static bool realtime_child_pipe(int fds[2]) {
	#ifdef __linux__
	if (pipe2(fds, O_CLOEXEC) != 0) return false;
#else
	if (pipe(fds) != 0) return false;
#endif
	for (int i = 0; i < 2; i++) {
		/* Avoid colliding with stdio even when the parent closed fd 0/1/2. */
		if (fds[i] < 3) {
			int replacement = fcntl(fds[i], F_DUPFD, 3);
			close(fds[i]);
			fds[i] = replacement;
		}
		if (fds[i] < 0 || fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) {
			int saved = errno;
			if (fds[0] >= 0) close(fds[0]);
			if (fds[1] >= 0) close(fds[1]);
			fds[0] = fds[1] = -1;
			errno = saved;
			return false;
		}
	}
	return true;
}
#endif

HL_PRIM realtime_child_process *HL_NAME(__process_spawn)(vstring *command, varray *arguments,
	vstring *cwd, varray *keys, varray *values, bool detached, bool new_process_group) {
#ifdef HL_WIN
	(void)new_process_group;
	if (command == NULL || command->length == 0) hl_error("Process command cannot be empty");
	int count = arguments == NULL ? 0 : arguments->size;
	int overrides = keys == NULL ? 0 : keys->size;
	if (overrides != (values == NULL ? 0 : values->size)) hl_error("Process environment keys/values differ in length");
	wchar_t *program = realtime_child_wide(command);
	wchar_t *directory = cwd == NULL || cwd->length == 0 ? NULL : realtime_child_wide(cwd);
	wchar_t **argv = calloc((size_t)count + 1, sizeof(wchar_t *));
	if (program == NULL || (cwd != NULL && cwd->length > 0 && directory == NULL) || argv == NULL) {
		free(program); free(directory); free(argv); hl_error("Could not allocate process launch configuration");
	}
	size_t command_size = realtime_child_quote_size(program) + 1;
	for (int i = 0; i < count; i++) {
		argv[i] = realtime_child_wide(hl_aptr(arguments, vstring *)[i]);
		if (argv[i] == NULL) {
			for (int j = 0; j < i; j++) free(argv[j]);
			free(program); free(directory); free(argv); hl_error("Invalid UTF-8 process argument");
		}
		command_size += realtime_child_quote_size(argv[i]) + 1;
	}
	wchar_t *command_line = calloc(command_size, sizeof(wchar_t));
	wchar_t *environment = realtime_child_environment(keys, values);
	if (command_line == NULL || (overrides > 0 && environment == NULL)) {
		for (int i = 0; i < count; i++) free(argv[i]);
		free(program); free(directory); free(argv); free(command_line); free(environment);
		hl_error("Could not allocate process launch configuration");
	}
	wchar_t *cursor = realtime_child_quote(command_line, program);
	for (int i = 0; i < count; i++) { *cursor++ = L' '; cursor = realtime_child_quote(cursor, argv[i]); }
	*cursor = 0;
	for (int i = 0; i < count; i++) free(argv[i]);
	free(argv); free(program);
	HANDLE child_stdin = NULL, parent_stdin = NULL, parent_stdout = NULL, child_stdout = NULL;
	HANDLE parent_stderr = NULL, child_stderr = NULL;
	if (!realtime_child_make_pipe(&child_stdin, &parent_stdin) ||
		!realtime_child_make_pipe(&parent_stdout, &child_stdout) ||
		!realtime_child_make_pipe(&parent_stderr, &child_stderr)) {
		DWORD error = GetLastError();
		realtime_child_handle_close(&child_stdin); realtime_child_handle_close(&parent_stdin);
		realtime_child_handle_close(&parent_stdout); realtime_child_handle_close(&child_stdout);
		realtime_child_handle_close(&parent_stderr); realtime_child_handle_close(&child_stderr);
		free(directory); free(command_line); free(environment); hl_error("Could not create process pipes: %d", (int)error);
	}
	SetHandleInformation(parent_stdin, HANDLE_FLAG_INHERIT, 0);
	SetHandleInformation(parent_stdout, HANDLE_FLAG_INHERIT, 0);
	SetHandleInformation(parent_stderr, HANDLE_FLAG_INHERIT, 0);
	HANDLE inherited_handles[3] = {child_stdin, child_stdout, child_stderr};
	SIZE_T attribute_bytes = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
	LPPROC_THREAD_ATTRIBUTE_LIST attributes = malloc(attribute_bytes);
	bool attributes_ready = attributes != NULL && InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes);
	if (!attributes_ready || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		inherited_handles, sizeof(inherited_handles), NULL, NULL)) {
		DWORD error = GetLastError();
		if (attributes_ready) DeleteProcThreadAttributeList(attributes);
		free(attributes); realtime_child_handle_close(&child_stdin); realtime_child_handle_close(&parent_stdin);
		realtime_child_handle_close(&parent_stdout); realtime_child_handle_close(&child_stdout);
		realtime_child_handle_close(&parent_stderr); realtime_child_handle_close(&child_stderr);
		free(directory); free(command_line); free(environment); hl_error("Could not configure process pipes: %d", (int)error);
	}
	HANDLE job = detached ? NULL : CreateJobObjectW(NULL, NULL);
	JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
		JOB_OBJECT_LIMIT_BREAKAWAY_OK;
	if (!detached && (job == NULL || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))) {
		DWORD error = GetLastError();
		if (job != NULL) CloseHandle(job);
		DeleteProcThreadAttributeList(attributes); free(attributes);
		realtime_child_handle_close(&child_stdin); realtime_child_handle_close(&parent_stdin);
		realtime_child_handle_close(&parent_stdout); realtime_child_handle_close(&child_stdout);
		realtime_child_handle_close(&parent_stderr); realtime_child_handle_close(&child_stderr);
		free(directory); free(command_line); free(environment); hl_error("Could not create process job: %d", (int)error);
	}
	STARTUPINFOEXW startup = {0};
	startup.StartupInfo.cb = sizeof(startup);
	startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	startup.StartupInfo.hStdInput = child_stdin;
	startup.StartupInfo.hStdOutput = child_stdout;
	startup.StartupInfo.hStdError = child_stderr;
	startup.lpAttributeList = attributes;
	PROCESS_INFORMATION information = {0};
	DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
		(detached ? CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB : 0);
	BOOL started = CreateProcessW(NULL, command_line, NULL, NULL, TRUE, flags, environment, directory,
		&startup.StartupInfo, &information);
	DWORD error = started ? ERROR_SUCCESS : GetLastError();
	DeleteProcThreadAttributeList(attributes); free(attributes);
	realtime_child_handle_close(&child_stdin); realtime_child_handle_close(&child_stdout);
	realtime_child_handle_close(&child_stderr);
	free(directory); free(command_line); free(environment);
	if (started && job != NULL && !AssignProcessToJobObject(job, information.hProcess)) {
		error = GetLastError(); TerminateProcess(information.hProcess, 1); WaitForSingleObject(information.hProcess, INFINITE); started = FALSE;
	}
	if (started && ResumeThread(information.hThread) == (DWORD)-1) {
		error = GetLastError();
		if (job != NULL) TerminateJobObject(job, 1); else TerminateProcess(information.hProcess, 1);
		WaitForSingleObject(information.hProcess, INFINITE); started = FALSE;
	}
	CloseHandle(information.hThread);
	if (!started) {
		CloseHandle(information.hProcess); if (job != NULL) CloseHandle(job);
		realtime_child_handle_close(&parent_stdin); realtime_child_handle_close(&parent_stdout); realtime_child_handle_close(&parent_stderr);
		hl_error("Could not start process: %d", (int)error);
	}
	realtime_child_process *p = hl_gc_alloc_finalizer(sizeof(realtime_child_process));
	memset(p, 0, sizeof(*p));
	p->finalize = realtime_child_cleanup; p->stdin_pipe = parent_stdin; p->stdout_pipe = parent_stdout;
	p->stderr_pipe = parent_stderr; p->process = information.hProcess; p->job = job; p->pid = information.dwProcessId;
	p->exit_status = (DWORD)-1; p->closed = false; p->exited = false; p->detached = detached;
	p->write_capacity = 1024u * 1024u;
	p->write_queue = malloc(p->write_capacity);
	if (p->write_queue == NULL || !InitializeCriticalSectionAndSpinCount(&p->write_mutex, 4000)) {
		realtime_child_cleanup(p); hl_error("Could not initialize process streaming pipes");
	}
	p->write_mutex_ready = true;
	p->writer_thread = CreateThread(NULL, 0, realtime_child_writer, p, 0, NULL);
	if (p->writer_thread == NULL) {
		realtime_child_cleanup(p); hl_error("Could not start process stdin writer");
	}
	return p;
#else
	if (command == NULL || command->length == 0) hl_error("Process command cannot be empty");
	int count = arguments == NULL ? 0 : arguments->size;
	int overrides = keys == NULL ? 0 : keys->size;
	if (overrides != (values == NULL ? 0 : values->size)) hl_error("Process environment keys/values differ in length");
	/* Copy all managed values before creating any OS resources. */
	char *program = realtime_utf8_copy(command);
	char *directory = cwd == NULL ? NULL : realtime_utf8_copy(cwd);
	char **argv = calloc((size_t)count + 2, sizeof(char *));
	int inherited = 0;
	while (environ[inherited] != NULL) inherited++;
	char **env = calloc((size_t)inherited + overrides + 1, sizeof(char *));
	if (!argv || !env) {
		free(program); free(directory); free(argv); free(env);
		hl_error("Could not allocate process launch configuration");
	}
	argv[0] = program;
	for (int i = 0; i < count; i++) argv[i + 1] = realtime_utf8_copy(hl_aptr(arguments, vstring *)[i]);
	for (int i = 0; i < inherited; i++) env[i] = strdup(environ[i]);
	int env_count = inherited, error = 0;
	for (int i = 0; i < overrides; i++) {
		char *key = realtime_utf8_copy(hl_aptr(keys, vstring *)[i]);
		char *value = realtime_utf8_copy(hl_aptr(values, vstring *)[i]);
		size_t length = strlen(key);
		if (length == 0 || strchr(key, '=') != NULL) error = EINVAL;
		char *entry = malloc(length + strlen(value) + 2);
		if (entry == NULL) error = ENOMEM;
		if (entry != NULL) {
			sprintf(entry, "%s=%s", key, value);
			int slot = 0;
			while (slot < env_count && !(strncmp(env[slot], key, length) == 0 && env[slot][length] == '=')) slot++;
			if (slot < env_count) free(env[slot]); else env_count++;
			env[slot] = entry;
		}
		free(key); free(value);
	}
	int pipes[3][2] = {{-1,-1},{-1,-1},{-1,-1}};
	posix_spawn_file_actions_t actions;
	posix_spawnattr_t spawn_attributes;
	bool actions_ready = false;
	bool attributes_ready = false;
	pid_t pid = -1;
	for (int i = 0; i < 3 && error == 0; i++) if (!realtime_child_pipe(pipes[i])) error = errno;
	/* Only the parent's ends are nonblocking. Child stdio remains ordinary blocking I/O. */
	int parent_ends[3] = {pipes[0][1], pipes[1][0], pipes[2][0]};
	for (int i = 0; i < 3 && error == 0; i++)
		if (fcntl(parent_ends[i], F_SETFL, O_NONBLOCK) < 0) error = errno;
	if (error == 0) { error = posix_spawn_file_actions_init(&actions); actions_ready = error == 0; }
	if (error == 0) { error = posix_spawnattr_init(&spawn_attributes); attributes_ready = error == 0; }
	if (error == 0 && new_process_group) error = posix_spawnattr_setpgroup(&spawn_attributes, 0);
	if (error == 0 && new_process_group) error = posix_spawnattr_setflags(&spawn_attributes, POSIX_SPAWN_SETPGROUP);
	for (int i = 0; i < 3 && error == 0; i++) error = posix_spawn_file_actions_adddup2(&actions, pipes[i][i == 0 ? 0 : 1], i);
	for (int i = 0; i < 3 && error == 0; i++)
		for (int j = 0; j < 2 && error == 0; j++) error = posix_spawn_file_actions_addclose(&actions, pipes[i][j]);
	if (error == 0 && directory != NULL && directory[0] != 0) {
#if defined(__linux__) || defined(__APPLE__)
		error = posix_spawn_file_actions_addchdir_np(&actions, directory);
#else
		error = ENOTSUP;
#endif
	}
	if (error == 0) error = posix_spawnp(&pid, program, &actions,
		new_process_group ? &spawn_attributes : NULL, argv, env);
	if (attributes_ready) posix_spawnattr_destroy(&spawn_attributes);
	if (actions_ready) posix_spawn_file_actions_destroy(&actions);
	for (int i = 0; i <= count; i++) free(argv[i]);
	for (int i = 0; i < env_count; i++) free(env[i]);
	free(argv); free(env); free(directory);
	if (error != 0) {
		for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) if (pipes[i][j] >= 0) close(pipes[i][j]);
		hl_error("Could not start process: %s", strerror(error));
	}
	close(pipes[0][0]); close(pipes[1][1]); close(pipes[2][1]);
	realtime_child_process *p = hl_gc_alloc_finalizer(sizeof(realtime_child_process));
	p->finalize = realtime_child_cleanup;
	p->stdin_fd = pipes[0][1]; p->stdout_fd = pipes[1][0]; p->stderr_fd = pipes[2][0];
	p->pid = pid; p->process_group = new_process_group ? pid : getpgrp(); p->owns_process_group = new_process_group;
	p->exit_status = -1; p->closed = false; p->exited = false; p->detached = detached;
	return p;
#endif
}

static void realtime_child_check(realtime_child_process *p) {
	if (p == NULL || p->closed) hl_error("Process is closed");
}
static int realtime_child_read(realtime_child_process *p, realtime_bytes *bytes, int offset, int length, bool stderr_stream) {
	realtime_child_check(p);
	realtime_bytes_bounds(bytes, offset, length);
#ifdef HL_WIN
	if (length == 0) return 0;
	HANDLE *pipe = stderr_stream ? &p->stderr_pipe : &p->stdout_pipe;
	if (*pipe == NULL) return -1;
	DWORD available = 0;
	if (!PeekNamedPipe(*pipe, NULL, 0, NULL, &available, NULL)) {
		DWORD error = GetLastError();
		if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) {
			realtime_child_handle_close(pipe); return -1;
		}
		hl_error("Could not inspect process output: %d", (int)error);
	}
	if (available == 0) {
		if (realtime_child_poll(p, false) >= 0) { realtime_child_handle_close(pipe); return -1; }
		return -2;
	}
	DWORD amount = (DWORD)((size_t)length < available ? (size_t)length : available), count = 0;
	if (!ReadFile(*pipe, bytes->data + offset, amount, &count, NULL)) {
		DWORD error = GetLastError();
		if (error == ERROR_NO_DATA) return -2;
		if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) {
			realtime_child_handle_close(pipe); return -1;
		}
		hl_error("Could not read process output: %d", (int)error);
	}
	return count == 0 ? -2 : (int)count;
#else
	if (length == 0) return 0;
	int *fd = stderr_stream ? &p->stderr_fd : &p->stdout_fd;
	if (*fd < 0) return -1;
	ssize_t count;
	do { count = read(*fd, bytes->data + offset, (size_t)length); } while (count < 0 && errno == EINTR);
	if (count > 0) return (int)count;
	if (count == 0) { realtime_child_fd_close(fd); return -1; }
	if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
	hl_error("Could not read process output: %s", strerror(errno));
#endif
	return -1;
}
HL_PRIM int HL_NAME(__child_read_stdout)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) { return realtime_child_read(p, bytes, offset, length, false); }
HL_PRIM int HL_NAME(__child_read_stderr)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) { return realtime_child_read(p, bytes, offset, length, true); }
HL_PRIM int HL_NAME(__child_write)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) {
	realtime_child_check(p);
	realtime_bytes_bounds(bytes, offset, length);
#ifdef HL_WIN
	if (length == 0) return 0;
	if (p->stdin_pipe == NULL || !p->write_mutex_ready) hl_error("Process stdin is closed");
	EnterCriticalSection(&p->write_mutex);
	if (p->write_failed) { LeaveCriticalSection(&p->write_mutex); hl_error("Could not write process stdin"); }
	if (p->write_close_requested) { LeaveCriticalSection(&p->write_mutex); hl_error("Process stdin is closed"); }
	size_t available = p->write_capacity - p->write_length - p->write_inflight;
	size_t accepted = (size_t)length < available ? (size_t)length : available;
	if (accepted != 0) {
		memcpy(p->write_queue + p->write_length, bytes->data + offset, accepted);
		p->write_length += accepted;
	}
	LeaveCriticalSection(&p->write_mutex);
	return (int)accepted;
#else
	if (p->stdin_fd < 0) hl_error("Process stdin is closed");
	if (length == 0) return 0;
	/* Suppress SIGPIPE only for this thread/write, preserving the caller's signal policy. */
	sigset_t blocked, previous, pending;
	sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
	int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
	if (mask_error != 0) hl_error("Could not block SIGPIPE");
	sigpending(&pending);
	bool already_pending = sigismember(&pending, SIGPIPE) == 1;
	ssize_t count;
	do { count = write(p->stdin_fd, bytes->data + offset, (size_t)length); } while (count < 0 && errno == EINTR);
	int saved = errno;
	if (count < 0 && saved == EPIPE && !already_pending) {
		/* sigwait is portable to macOS; EPIPE guarantees this thread generated SIGPIPE. */
		int signal_number;
		sigpending(&pending);
		if (sigismember(&pending, SIGPIPE) == 1) sigwait(&blocked, &signal_number);
	}
	pthread_sigmask(SIG_SETMASK, &previous, NULL);
	if (count >= 0) return (int)count;
	if (saved == EAGAIN || saved == EWOULDBLOCK) return 0;
	hl_error("Could not write process stdin: %s", strerror(saved));
#endif
	return 0;
}
HL_PRIM void HL_NAME(__child_close_stdin)(realtime_child_process *p) {
	realtime_child_check(p);
#ifdef HL_WIN
	if (p->write_mutex_ready) {
		EnterCriticalSection(&p->write_mutex);
		p->write_close_requested = true;
		LeaveCriticalSection(&p->write_mutex);
	}
#else
	realtime_child_fd_close(&p->stdin_fd);
#endif
}
HL_PRIM int HL_NAME(__child_poll_exit)(realtime_child_process *p) {
	realtime_child_check(p);
	return realtime_child_poll(p, false);
}
HL_PRIM void HL_NAME(__child_cancel)(realtime_child_process *p) {
	realtime_child_check(p);
#ifdef HL_WIN
	if (realtime_child_poll(p, false) < 0) {
		BOOL stopped = p->job != NULL ? TerminateJobObject(p->job, 1) : TerminateProcess(p->process, 1);
		if (!stopped) hl_error("Could not cancel process: %d", (int)GetLastError());
	}
#else
	if (realtime_child_poll(p, false) < 0 &&
		kill(p->owns_process_group ? -p->process_group : p->pid, SIGTERM) < 0 && errno != ESRCH)
		hl_error("Could not cancel process");
#endif
}
HL_PRIM void HL_NAME(__child_close)(realtime_child_process *p) {
	if (p != NULL) realtime_child_cleanup(p);
}
