/* Child processes for std.process: started with each standard stream piped, inherited or discarded, read and written
   without blocking, and waited for (output, room for input, or the exit) with a timeout. A failure the program can meet
   (no such program, a missing directory, a child that stopped reading) is recorded on the thread for std.process to
   report as a ProcessError; a misuse (an empty command, a closed child) throws. */
#ifdef HL_WIN
#include <windows.h>
#include <wchar.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <pthread.h>
#include <time.h>
#ifdef __ANDROID__
#include <dlfcn.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
#include <sys/event.h>
#define REALTIME_CHILD_KQUEUE 1
#endif
extern char **environ;
#endif

#if defined(_MSC_VER)
#define REALTIME_CHILD_TLS __declspec(thread)
#else
#define REALTIME_CHILD_TLS _Thread_local
#endif

/* Why an operation failed: std.process.ProcessError's cases, in their order (TimedOut is std.process's own). */
enum {
	REALTIME_CHILD_OK,
	REALTIME_CHILD_NOT_FOUND,
	REALTIME_CHILD_PERMISSION_DENIED,
	REALTIME_CHILD_DIRECTORY_NOT_FOUND,
	REALTIME_CHILD_INPUT_CLOSED,
	REALTIME_CHILD_UNSUPPORTED,
	REALTIME_CHILD_IO
};

/* What a standard stream of the child is: std.process.Stdio's cases, in their order. */
enum { REALTIME_CHILD_PIPE, REALTIME_CHILD_INHERIT, REALTIME_CHILD_DISCARD };

/* How a child starts. */
enum {
	REALTIME_CHILD_DETACHED = 1,
	/* The child leads a process group of its own, which terminating and closing it end as a whole. */
	REALTIME_CHILD_GROUP = 2,
	/* Windows: the arguments follow the program on its command line as given, unquoted (a shell's command line). */
	REALTIME_CHILD_VERBATIM = 4,
	/* The environment given is the whole of the child's, not changes to this process's. */
	REALTIME_CHILD_REPLACE_ENVIRONMENT = 8
};

/* What a wait waits for, and what it answers ready. */
enum { REALTIME_CHILD_STDOUT = 1, REALTIME_CHILD_STDERR = 2, REALTIME_CHILD_STDIN = 4, REALTIME_CHILD_EXIT = 8 };

static REALTIME_CHILD_TLS int realtime_child_kind;
static REALTIME_CHILD_TLS int realtime_child_code;

static bool realtime_child_succeed(void) {
	realtime_child_kind = REALTIME_CHILD_OK;
	realtime_child_code = 0;
	return true;
}

static bool realtime_child_refuse(int kind, int code) {
	realtime_child_kind = kind;
	realtime_child_code = code;
	return false;
}

#ifdef HL_WIN
/* Output read through an overlapped pipe, so a wait can include it: one read is kept in flight into `buffer`. */
typedef struct {
	HANDLE pipe, event;
	OVERLAPPED overlapped;
	unsigned char buffer[16384];
	DWORD available, offset;
	bool pending, ended;
} realtime_child_stream;
#endif

typedef struct realtime_child_process {
	void (*finalize)(void *);
#ifdef HL_WIN
	HANDLE stdin_pipe;
	realtime_child_stream *out[2];
	HANDLE writer_thread;
	HANDLE process, job;
	DWORD pid;
	CRITICAL_SECTION write_mutex;
	/* Signalled when the writer has work: bytes queued or stdin to close. */
	CONDITION_VARIABLE write_ready;
	/* Set when the writer has made room in the queue, or failed. */
	HANDLE write_space;
	unsigned char *write_queue;
	size_t write_length, write_inflight, write_capacity;
	bool write_close_requested, write_failed, write_mutex_ready, stdin_piped;
#else
	int stdin_fd, stdout_fd, stderr_fd;
	/* A descriptor readable once the child exits (Linux's pidfd), or -1. */
	int exit_fd;
	int pid;
	int process_group;
	bool owns_process_group;
#endif
	/* The exit, once known: a code (kind 0) or, on POSIX, the signal that ended the child (kind 1). */
	int exit_kind, exit_value;
	bool closed, exited, detached;
} realtime_child_process;

static void realtime_child_check(realtime_child_process *p) {
	if (p == NULL || p->closed) hl_error("Process is closed");
}

#ifdef HL_WIN
static int realtime_child_kind_of(DWORD error) {
	switch (error) {
	case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_BAD_EXE_FORMAT: case ERROR_INVALID_NAME:
		return REALTIME_CHILD_NOT_FOUND;
	case ERROR_ACCESS_DENIED: return REALTIME_CHILD_PERMISSION_DENIED;
	case ERROR_DIRECTORY: return REALTIME_CHILD_DIRECTORY_NOT_FOUND;
	case ERROR_BROKEN_PIPE: case ERROR_NO_DATA: case ERROR_PIPE_NOT_CONNECTED: return REALTIME_CHILD_INPUT_CLOSED;
	default: return REALTIME_CHILD_IO;
	}
}

static bool realtime_child_fail(DWORD error) {
	return realtime_child_refuse(realtime_child_kind_of(error), (int)error);
}

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

/* The room `value` takes quoted for a program's command line (the C runtime's rules), and the quoting itself. */
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

/* Whether the child has exited, recording how; false while it runs, or after recording a failure to ask. */
static bool realtime_child_reap(realtime_child_process *p, DWORD milliseconds) {
	if (p->exited) return true;
	DWORD result = WaitForSingleObject(p->process, milliseconds);
	if (result == WAIT_TIMEOUT) return false;
	DWORD code = 0;
	if (result != WAIT_OBJECT_0 || !GetExitCodeProcess(p->process, &code)) return realtime_child_fail(GetLastError());
	p->exit_kind = 0;
	p->exit_value = (int)code;
	p->exited = true;
	return true;
}

static void realtime_child_handle_close(HANDLE *handle) {
	if (*handle != NULL && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
	*handle = NULL;
}

static void realtime_child_stream_free(realtime_child_stream **slot) {
	realtime_child_stream *s = *slot;
	if (s == NULL) return;
	if (s->pending) {
		DWORD count;
		CancelIoEx(s->pipe, &s->overlapped);
		GetOverlappedResult(s->pipe, &s->overlapped, &count, TRUE);
	}
	realtime_child_handle_close(&s->pipe);
	realtime_child_handle_close(&s->event);
	free(s);
	*slot = NULL;
}

static void realtime_child_cleanup(void *value) {
	realtime_child_process *p = value;
	if (p->closed) return;
	/* Closing a kill-on-close job also ends what the child started, even when the child itself has exited. */
	if (p->job != NULL) TerminateJobObject(p->job, 1);
	else if (!p->detached && !p->exited) TerminateProcess(p->process, 1);
	if (!p->detached) (void)realtime_child_reap(p, INFINITE);
	if (p->write_mutex_ready) {
		EnterCriticalSection(&p->write_mutex);
		p->write_close_requested = true;
		WakeConditionVariable(&p->write_ready);
		LeaveCriticalSection(&p->write_mutex);
	}
	if (p->writer_thread != NULL) {
		/* A child that still runs (detached) may leave its input unread; the writer must not wait on it. */
		CancelSynchronousIo(p->writer_thread);
		WaitForSingleObject(p->writer_thread, INFINITE);
		realtime_child_handle_close(&p->writer_thread);
	}
	realtime_child_handle_close(&p->stdin_pipe);
	realtime_child_stream_free(&p->out[0]);
	realtime_child_stream_free(&p->out[1]);
	realtime_child_handle_close(&p->process);
	realtime_child_handle_close(&p->job);
	realtime_child_handle_close(&p->write_space);
	if (p->write_mutex_ready) DeleteCriticalSection(&p->write_mutex);
	free(p->write_queue);
	p->closed = true;
}

static DWORD WINAPI realtime_child_writer(void *value) {
	realtime_child_process *p = value;
	unsigned char buffer[16384];
	/* Through HashLink, so a profiling session records the name even if the writer exits before its next thread list. */
	hl_thread_set_name(hl_thread_current(), "std.process.stdin");
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
					SetEvent(p->write_space);
					return 0;
				}
				offset += written;
			}
			EnterCriticalSection(&p->write_mutex);
			p->write_inflight -= amount;
			LeaveCriticalSection(&p->write_mutex);
			SetEvent(p->write_space);
			continue;
		}
		if (!p->write_close_requested) {
			/* Nothing queued: wait for bytes or a close rather than polling. */
			SleepConditionVariableCS(&p->write_ready, &p->write_mutex, INFINITE);
			LeaveCriticalSection(&p->write_mutex);
			continue;
		}
		LeaveCriticalSection(&p->write_mutex);
		realtime_child_handle_close(&p->stdin_pipe);
		return 0;
	}
}

/* A pipe whose read end the child inherits, for its input. */
static bool realtime_child_input_pipe(HANDLE *child_read, HANDLE *parent_write) {
	SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
	if (!CreatePipe(child_read, parent_write, &attributes, 0)) return false;
	SetHandleInformation(*parent_write, HANDLE_FLAG_INHERIT, 0);
	return true;
}

/* A pipe for the child's output: the parent reads its end overlapped, the child inherits the other. */
static bool realtime_child_output_pipe(realtime_child_stream **stream, HANDLE *child_write) {
	static volatile LONG serial = 0;
	wchar_t name[96];
	swprintf(name, 96, L"\\\\.\\pipe\\std-process-%lu-%ld", (unsigned long)GetCurrentProcessId(),
		(long)InterlockedIncrement(&serial));
	HANDLE read_end = CreateNamedPipeW(name, PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
		PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
	if (read_end == INVALID_HANDLE_VALUE) return false;
	SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
	HANDLE write_end = CreateFileW(name, GENERIC_WRITE, 0, &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	realtime_child_stream *s = calloc(1, sizeof(realtime_child_stream));
	HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (write_end == INVALID_HANDLE_VALUE || s == NULL || event == NULL) {
		DWORD error = GetLastError();
		CloseHandle(read_end);
		if (write_end != INVALID_HANDLE_VALUE) CloseHandle(write_end);
		if (event != NULL) CloseHandle(event);
		free(s);
		SetLastError(error == 0 ? ERROR_NOT_ENOUGH_MEMORY : error);
		return false;
	}
	s->pipe = read_end;
	s->event = event;
	s->overlapped.hEvent = event;
	*stream = s;
	*child_write = write_end;
	return true;
}

/* A handle the child inherits as one of its standard streams: this process's own, or one that discards. */
static HANDLE realtime_child_stdio_handle(int mode, DWORD which) {
	SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
	if (mode == REALTIME_CHILD_INHERIT) {
		HANDLE own = GetStdHandle(which), copy = NULL;
		if (own != NULL && own != INVALID_HANDLE_VALUE &&
			DuplicateHandle(GetCurrentProcess(), own, GetCurrentProcess(), &copy, 0, TRUE, DUPLICATE_SAME_ACCESS))
			return copy;
		/* A process without that stream (a windowed app) gives the child none either. */
	}
	return CreateFileW(L"NUL", which == STD_INPUT_HANDLE ? GENERIC_READ : GENERIC_WRITE,
		FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_EXISTING, 0, NULL);
}

/* Keeps a read in flight, or takes the one that completed, without waiting: false after recording a failure. */
static bool realtime_child_stream_fill(realtime_child_stream *s) {
	if (s->ended || s->offset < s->available) return true;
	if (!s->pending) {
		s->offset = s->available = 0;
		if (!ReadFile(s->pipe, s->buffer, sizeof(s->buffer), NULL, &s->overlapped)) {
			DWORD error = GetLastError();
			if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED || error == ERROR_HANDLE_EOF) {
				s->ended = true;
				return true;
			}
			if (error != ERROR_IO_PENDING) return realtime_child_fail(error);
		}
		s->pending = true;
	}
	DWORD count = 0;
	if (!GetOverlappedResult(s->pipe, &s->overlapped, &count, FALSE)) {
		DWORD error = GetLastError();
		if (error == ERROR_IO_INCOMPLETE) return true;
		s->pending = false;
		if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED || error == ERROR_HANDLE_EOF) {
			s->ended = true;
			return true;
		}
		return realtime_child_fail(error);
	}
	s->pending = false;
	s->available = count;
	return true;
}

static bool realtime_child_stream_ready(realtime_child_stream *s) {
	return s->ended || s->offset < s->available;
}
#else
static int realtime_child_kind_of(int error) {
	switch (error) {
	case ENOENT: case ENOTDIR: case ENOEXEC: return REALTIME_CHILD_NOT_FOUND;
	case EACCES: case EPERM: return REALTIME_CHILD_PERMISSION_DENIED;
	case EPIPE: return REALTIME_CHILD_INPUT_CLOSED;
	case ENOTSUP: return REALTIME_CHILD_UNSUPPORTED;
	default: return REALTIME_CHILD_IO;
	}
}

static bool realtime_child_fail(int error) {
	return realtime_child_refuse(realtime_child_kind_of(error), error);
}

static void realtime_child_record_status(realtime_child_process *p, int status) {
	if (WIFSIGNALED(status)) {
		p->exit_kind = 1;
		p->exit_value = WTERMSIG(status);
	} else {
		p->exit_kind = 0;
		p->exit_value = WEXITSTATUS(status);
	}
	p->exited = true;
}

/* Whether the child has exited, recording how; false while it runs, or after recording a failure to ask. */
static bool realtime_child_reap(realtime_child_process *p, bool wait) {
	if (p->exited) return true;
	int status;
	pid_t result;
	do { result = waitpid(p->pid, &status, wait ? 0 : WNOHANG); } while (result < 0 && errno == EINTR);
	if (result == 0) return false;
	if (result < 0) return realtime_child_fail(errno);
	realtime_child_record_status(p, status);
	return true;
}

static void realtime_child_fd_close(int *fd) {
	if (*fd >= 0) close(*fd);
	*fd = -1;
}

static void realtime_child_cleanup(void *value) {
	realtime_child_process *p = value;
	if (p->closed) return;
	/* Explicit ownership: close never leaves a live child or a zombie behind, unless it was started detached. */
	if (!p->detached && !realtime_child_reap(p, false)) {
		(void)kill(p->owns_process_group ? -p->process_group : p->pid, SIGKILL);
		(void)realtime_child_reap(p, true);
	}
	/* What the child started in its group goes with it. */
	if (!p->detached && p->owns_process_group) (void)kill(-p->process_group, SIGKILL);
	realtime_child_fd_close(&p->stdin_fd);
	realtime_child_fd_close(&p->stdout_fd);
	realtime_child_fd_close(&p->stderr_fd);
	realtime_child_fd_close(&p->exit_fd);
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

/* A descriptor that becomes readable when `pid` exits, or -1 where the kernel has none. */
static int realtime_child_exit_descriptor(pid_t pid) {
#if defined(__linux__) && defined(SYS_pidfd_open)
	int fd = (int)syscall(SYS_pidfd_open, pid, 0);
	if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fd < 0 ? -1 : fd;
#else
	(void)pid;
	return -1;
#endif
}

static int64_t realtime_child_now_ms(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
#endif

/* Whether `directory` names a directory: a missing one is told apart from a missing program before starting. */
static bool realtime_child_directory_exists(vstring *directory) {
	if (directory == NULL || directory->length == 0) return true;
#ifdef HL_WIN
	wchar_t *path = realtime_child_wide(directory);
	if (path == NULL) return false;
	DWORD attributes = GetFileAttributesW(path);
	free(path);
	return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
	char *path = realtime_utf8_copy(directory);
	struct stat info;
	bool exists = stat(path, &info) == 0 && S_ISDIR(info.st_mode);
	free(path);
	return exists;
#endif
}

#ifdef HL_WIN
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

static bool realtime_child_environment_grow(wchar_t ***entries, int count, int *capacity) {
	if (count < *capacity) return true;
	int next = *capacity == 0 ? 32 : *capacity * 2;
	wchar_t **grown = realloc(*entries, (size_t)next * sizeof(wchar_t *));
	if (grown == NULL) return false;
	*entries = grown;
	*capacity = next;
	return true;
}

/* The child's environment block: this process's with `keys` set to `values`, or only those when `replace`. NULL with
   `*failed` false means the child inherits this process's environment unchanged. */
static wchar_t *realtime_child_environment(varray *keys, varray *values, bool replace, bool *failed) {
	*failed = false;
	int overrides = keys == NULL ? 0 : keys->size;
	if (overrides == 0 && !replace) return NULL;
	wchar_t **entries = NULL, *block = NULL;
	int count = 0, capacity = 0;
	if (!replace) {
		LPWCH inherited = GetEnvironmentStringsW();
		if (inherited == NULL) { *failed = true; return NULL; }
		for (const wchar_t *at = inherited; *at != 0; at += wcslen(at) + 1) {
			size_t length = wcslen(at) + 1;
			if (!realtime_child_environment_grow(&entries, count, &capacity) ||
				(entries[count] = malloc(length * sizeof(wchar_t))) == NULL) {
				FreeEnvironmentStringsW(inherited); realtime_child_free_environment(entries, count, NULL);
				*failed = true; return NULL;
			}
			memcpy(entries[count++], at, length * sizeof(wchar_t));
		}
		FreeEnvironmentStringsW(inherited);
	}
	for (int index = 0; index < overrides; index++) {
		wchar_t *key = realtime_child_wide(hl_aptr(keys, vstring *)[index]);
		wchar_t *value = realtime_child_wide(hl_aptr(values, vstring *)[index]);
		size_t key_length = key == NULL ? 0 : wcslen(key), value_length = value == NULL ? 0 : wcslen(value);
		wchar_t *entry = key == NULL || value == NULL ? NULL : malloc((key_length + value_length + 2) * sizeof(wchar_t));
		if (entry == NULL) {
			free(key); free(value); realtime_child_free_environment(entries, count, NULL);
			*failed = true; return NULL;
		}
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
			if (!realtime_child_environment_grow(&entries, count, &capacity)) {
				free(entry); free(key); free(value); realtime_child_free_environment(entries, count, NULL);
				*failed = true; return NULL;
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
	if (block == NULL) { realtime_child_free_environment(entries, count, NULL); *failed = true; return NULL; }
	wchar_t *cursor = block;
	for (int i = 0; i < count; i++) {
		size_t length = wcslen(entries[i]) + 1;
		memcpy(cursor, entries[i], length * sizeof(wchar_t)); cursor += length;
	}
	*cursor = 0;
	realtime_child_free_environment(entries, count, NULL);
	return block;
}

/* Whether a detached child may leave the job this process runs in. Asking is one cheap call; trying and retrying after
   ERROR_ACCESS_DENIED made every detached start create the process twice inside a job that forbids breakaway. */
static bool realtime_child_may_break_away(void) {
	static int known = -1;
	if (known >= 0) return known != 0;
	BOOL inJob = FALSE;
	int allowed = 1;
	if (IsProcessInJob(GetCurrentProcess(), NULL, &inJob) && inJob) {
		JOBOBJECT_EXTENDED_LIMIT_INFORMATION current = {0};
		allowed = QueryInformationJobObject(NULL, JobObjectExtendedLimitInformation, &current, sizeof(current), NULL) &&
			(current.BasicLimitInformation.LimitFlags & (JOB_OBJECT_LIMIT_BREAKAWAY_OK | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK)) != 0;
	}
	known = allowed ? 1 : 0;
	return allowed != 0;
}
#endif

static void realtime_child_validate(vstring *command, varray *arguments, varray *keys, varray *values) {
	if (command == NULL || command->length == 0) hl_error("Process command cannot be empty");
	if ((keys == NULL ? 0 : keys->size) != (values == NULL ? 0 : values->size))
		hl_error("Process environment keys/values differ in length");
	for (int i = 0; keys != NULL && i < keys->size; i++) {
		vstring *key = hl_aptr(keys, vstring *)[i], *value = hl_aptr(values, vstring *)[i];
		if (key == NULL || key->length == 0) hl_error("An environment variable needs a name");
		const uchar *name = (const uchar *)realtime_string_data(key);
#ifdef _WIN32
		/* Windows' own =C: entries (a drive's working directory) start with '='; it ends any other name. */
		int first = 1;
#else
		int first = 0;
#endif
		for (int at = first; at < key->length; at++)
			if (name[at] == '=') hl_error("An environment variable name holds '='");
		if (value == NULL) hl_error("An environment variable's value is null");
	}
	for (int i = 0; arguments != NULL && i < arguments->size; i++) {
		vstring *argument = hl_aptr(arguments, vstring *)[i];
		if (argument == NULL) hl_error("A process argument is null");
	}
}

/*
 * Starts `command` with `arguments` in `cwd` (empty: this process's). `keys` and `values` change the environment the
 * child inherits, or are its whole environment with REALTIME_CHILD_REPLACE_ENVIRONMENT. `stdio` holds the mode of
 * stdin, stdout and stderr in bits 0-1, 2-3 and 4-5. Answers null after recording why the child could not start.
 */
HL_PRIM realtime_child_process *HL_NAME(__child_spawn)(vstring *command, varray *arguments, vstring *cwd, varray *keys,
	varray *values, int stdio, int flags) {
	realtime_child_validate(command, arguments, keys, values);
	int modes[3] = {stdio & 3, (stdio >> 2) & 3, (stdio >> 4) & 3};
	bool detached = (flags & REALTIME_CHILD_DETACHED) != 0;
	if (!realtime_child_directory_exists(cwd)) {
		realtime_child_refuse(REALTIME_CHILD_DIRECTORY_NOT_FOUND, 0);
		return NULL;
	}
#ifdef HL_WIN
	int count = arguments == NULL ? 0 : arguments->size;
	bool verbatim = (flags & REALTIME_CHILD_VERBATIM) != 0;
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
		command_size += (verbatim ? wcslen(argv[i]) : realtime_child_quote_size(argv[i])) + 1;
	}
	wchar_t *command_line = calloc(command_size, sizeof(wchar_t));
	bool environment_failed;
	wchar_t *environment = realtime_child_environment(keys, values, (flags & REALTIME_CHILD_REPLACE_ENVIRONMENT) != 0,
		&environment_failed);
	if (command_line == NULL || environment_failed) {
		for (int i = 0; i < count; i++) free(argv[i]);
		free(program); free(directory); free(argv); free(command_line); free(environment);
		hl_error("Could not allocate process launch configuration");
	}
	wchar_t *cursor = realtime_child_quote(command_line, program);
	for (int i = 0; i < count; i++) {
		*cursor++ = L' ';
		if (verbatim) {
			size_t length = wcslen(argv[i]);
			memcpy(cursor, argv[i], length * sizeof(wchar_t));
			cursor += length;
		} else cursor = realtime_child_quote(cursor, argv[i]);
	}
	*cursor = 0;
	for (int i = 0; i < count; i++) free(argv[i]);
	free(argv); free(program);
	/* The child's ends of its three streams, and the parent's ends of the piped ones. */
	HANDLE child_ends[3] = {NULL, NULL, NULL}, parent_stdin = NULL;
	realtime_child_stream *outputs[2] = {NULL, NULL};
	DWORD error = ERROR_SUCCESS;
	static const DWORD which[3] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
	for (int i = 0; i < 3 && error == ERROR_SUCCESS; i++) {
		bool made;
		if (modes[i] != REALTIME_CHILD_PIPE) {
			child_ends[i] = realtime_child_stdio_handle(modes[i], which[i]);
			made = child_ends[i] != INVALID_HANDLE_VALUE;
			if (!made) child_ends[i] = NULL;
		} else if (i == 0) made = realtime_child_input_pipe(&child_ends[0], &parent_stdin);
		else made = realtime_child_output_pipe(&outputs[i - 1], &child_ends[i]);
		if (!made) error = GetLastError();
	}
	LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
	bool attributes_ready = false;
	if (error == ERROR_SUCCESS) {
		SIZE_T attribute_bytes = 0;
		InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
		attributes = malloc(attribute_bytes);
		attributes_ready = attributes != NULL && InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes);
		/* The child inherits its three streams and no other handle this process holds. */
		if (!attributes_ready || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
			child_ends, sizeof(child_ends), NULL, NULL)) error = attributes == NULL ? ERROR_NOT_ENOUGH_MEMORY : GetLastError();
	}
	HANDLE job = NULL;
	if (error == ERROR_SUCCESS && !detached) {
		JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
		limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
		job = CreateJobObjectW(NULL, NULL);
		if (job == NULL || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
			error = GetLastError();
	}
	PROCESS_INFORMATION information = {0};
	BOOL started = FALSE;
	if (error == ERROR_SUCCESS) {
		STARTUPINFOEXW startup = {0};
		startup.StartupInfo.cb = sizeof(startup);
		startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
		startup.StartupInfo.hStdInput = child_ends[0];
		startup.StartupInfo.hStdOutput = child_ends[1];
		startup.StartupInfo.hStdError = child_ends[2];
		startup.lpAttributeList = attributes;
		DWORD creation = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
			(detached ? CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | (realtime_child_may_break_away() ? CREATE_BREAKAWAY_FROM_JOB : 0) : 0);
		started = CreateProcessW(NULL, command_line, NULL, NULL, TRUE, creation, environment, directory,
			&startup.StartupInfo, &information);
		error = started ? ERROR_SUCCESS : GetLastError();
		// A job that does not allow breakaway (a sandbox, a CI runner, some terminals) refuses CREATE_BREAKAWAY_FROM_JOB
		// with ERROR_ACCESS_DENIED. The detached child then starts inside that job instead: it still outlives this
		// process, but not the job.
		if (!started && detached && error == ERROR_ACCESS_DENIED) {
			started = CreateProcessW(NULL, command_line, NULL, NULL, TRUE, creation & ~CREATE_BREAKAWAY_FROM_JOB,
				environment, directory, &startup.StartupInfo, &information);
			error = started ? ERROR_SUCCESS : GetLastError();
		}
	}
	if (attributes_ready) DeleteProcThreadAttributeList(attributes);
	free(attributes);
	for (int i = 0; i < 3; i++) realtime_child_handle_close(&child_ends[i]);
	free(directory); free(command_line); free(environment);
	if (started && job != NULL && !AssignProcessToJobObject(job, information.hProcess)) {
		error = GetLastError(); TerminateProcess(information.hProcess, 1); WaitForSingleObject(information.hProcess, INFINITE);
		started = FALSE;
	}
	if (started && ResumeThread(information.hThread) == (DWORD)-1) {
		error = GetLastError();
		if (job != NULL) TerminateJobObject(job, 1); else TerminateProcess(information.hProcess, 1);
		WaitForSingleObject(information.hProcess, INFINITE); started = FALSE;
	}
	if (information.hThread != NULL) CloseHandle(information.hThread);
	if (!started) {
		if (information.hProcess != NULL) CloseHandle(information.hProcess);
		if (job != NULL) CloseHandle(job);
		realtime_child_handle_close(&parent_stdin);
		realtime_child_stream_free(&outputs[0]);
		realtime_child_stream_free(&outputs[1]);
		realtime_child_fail(error);
		return NULL;
	}
	realtime_child_process *p = hl_gc_alloc_finalizer(sizeof(realtime_child_process));
	memset(p, 0, sizeof(*p));
	p->finalize = realtime_child_cleanup; p->stdin_pipe = parent_stdin; p->out[0] = outputs[0]; p->out[1] = outputs[1];
	p->process = information.hProcess; p->job = job; p->pid = information.dwProcessId; p->detached = detached;
	p->stdin_piped = parent_stdin != NULL;
	if (p->stdin_piped) {
		p->write_capacity = 1024u * 1024u;
		p->write_queue = malloc(p->write_capacity);
		p->write_space = CreateEventW(NULL, FALSE, FALSE, NULL);
		if (p->write_queue == NULL || p->write_space == NULL || !InitializeCriticalSectionAndSpinCount(&p->write_mutex, 4000)) {
			realtime_child_cleanup(p); hl_error("Could not initialize process streaming pipes");
		}
		InitializeConditionVariable(&p->write_ready);
		p->write_mutex_ready = true;
		p->writer_thread = CreateThread(NULL, 0, realtime_child_writer, p, 0, NULL);
		if (p->writer_thread == NULL) {
			realtime_child_cleanup(p); hl_error("Could not start process stdin writer");
		}
	}
	realtime_child_succeed();
	return p;
#else
	bool group = (flags & REALTIME_CHILD_GROUP) != 0;
	int count = arguments == NULL ? 0 : arguments->size;
	int overrides = keys == NULL ? 0 : keys->size;
	bool replace = (flags & REALTIME_CHILD_REPLACE_ENVIRONMENT) != 0;
	/* Copy all managed values before creating any OS resources. */
	char *program = realtime_utf8_copy(command);
	char *directory = cwd == NULL ? NULL : realtime_utf8_copy(cwd);
	char **argv = calloc((size_t)count + 2, sizeof(char *));
	int inherited = 0;
	if (!replace) while (environ[inherited] != NULL) inherited++;
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
		char *entry = malloc(length + strlen(value) + 2);
		if (entry == NULL) error = ENOMEM;
		else {
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
	for (int i = 0; i < 3 && error == 0; i++)
		if (modes[i] == REALTIME_CHILD_PIPE && !realtime_child_pipe(pipes[i])) error = errno;
	/* Only the parent's ends are nonblocking. Child stdio remains ordinary blocking I/O. */
	int parent_ends[3] = {pipes[0][1], pipes[1][0], pipes[2][0]};
	for (int i = 0; i < 3 && error == 0; i++)
		if (parent_ends[i] >= 0 && fcntl(parent_ends[i], F_SETFL, O_NONBLOCK) < 0) error = errno;
	if (error == 0) { error = posix_spawn_file_actions_init(&actions); actions_ready = error == 0; }
	if (error == 0) { error = posix_spawnattr_init(&spawn_attributes); attributes_ready = error == 0; }
	short spawn_flags = 0;
	if (error == 0 && group) {
		error = posix_spawnattr_setpgroup(&spawn_attributes, 0);
		spawn_flags |= POSIX_SPAWN_SETPGROUP;
	}
#ifdef __APPLE__
	/* The child gets its stdio and nothing else: a descriptor the parent opened without O_CLOEXEC (a lock, a socket)
	   must not outlive the parent in it. Linux has no such flag; its descriptors are opened O_CLOEXEC. */
	spawn_flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
	if (error == 0 && spawn_flags != 0) error = posix_spawnattr_setflags(&spawn_attributes, spawn_flags);
	for (int i = 0; i < 3 && error == 0; i++) {
		if (modes[i] == REALTIME_CHILD_PIPE) error = posix_spawn_file_actions_adddup2(&actions, pipes[i][i == 0 ? 0 : 1], i);
		else if (modes[i] == REALTIME_CHILD_DISCARD)
			error = posix_spawn_file_actions_addopen(&actions, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0);
#ifdef __APPLE__
		/* An inherited stream is named, or POSIX_SPAWN_CLOEXEC_DEFAULT closes it too. */
		else error = posix_spawn_file_actions_addinherit_np(&actions, i);
#endif
	}
	for (int i = 0; i < 3 && error == 0; i++)
		for (int j = 0; j < 2 && error == 0; j++)
			if (pipes[i][j] >= 0) error = posix_spawn_file_actions_addclose(&actions, pipes[i][j]);
	if (error == 0 && directory != NULL && directory[0] != 0) {
#if defined(__ANDROID__) && __ANDROID_API__ < 34
		/* Android's C library declares it from API 34. A build for an older API looks it up, so a device that has it still
		   starts the child in its directory and an older one reports that a working directory is not supported. */
		typedef int (*addchdir_fn)(posix_spawn_file_actions_t *, const char *);
		addchdir_fn addchdir = (addchdir_fn)dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
		error = addchdir ? addchdir(&actions, directory) : ENOTSUP;
#elif defined(__linux__) || defined(__APPLE__)
		error = posix_spawn_file_actions_addchdir_np(&actions, directory);
#else
		error = ENOTSUP;
#endif
	}
	if (error == 0) error = posix_spawnp(&pid, program, &actions, &spawn_attributes, argv, env);
	if (attributes_ready) posix_spawnattr_destroy(&spawn_attributes);
	if (actions_ready) posix_spawn_file_actions_destroy(&actions);
	for (int i = 0; i <= count; i++) free(argv[i]);
	for (int i = 0; i < env_count; i++) free(env[i]);
	free(argv); free(env); free(directory);
	if (error != 0) {
		for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) if (pipes[i][j] >= 0) close(pipes[i][j]);
		realtime_child_fail(error);
		return NULL;
	}
	if (pipes[0][0] >= 0) close(pipes[0][0]);
	if (pipes[1][1] >= 0) close(pipes[1][1]);
	if (pipes[2][1] >= 0) close(pipes[2][1]);
	realtime_child_process *p = hl_gc_alloc_finalizer(sizeof(realtime_child_process));
	memset(p, 0, sizeof(*p));
	p->finalize = realtime_child_cleanup;
	p->stdin_fd = parent_ends[0]; p->stdout_fd = parent_ends[1]; p->stderr_fd = parent_ends[2];
	p->exit_fd = realtime_child_exit_descriptor(pid);
	p->pid = pid; p->process_group = group ? pid : getpgrp(); p->owns_process_group = group;
	p->detached = detached;
	realtime_child_succeed();
	return p;
#endif
}

/* Reads what is there without waiting: how many bytes, -1 at the end, -2 when none are ready, -3 after a failure. */
static int realtime_child_read(realtime_child_process *p, realtime_bytes *bytes, int offset, int length, int stream) {
	realtime_child_check(p);
	realtime_bytes_bounds(bytes, offset, length);
	realtime_child_succeed();
	if (length == 0) return 0;
#ifdef HL_WIN
	realtime_child_stream *s = p->out[stream];
	if (s == NULL) hl_error("The process's output is not piped");
	if (!realtime_child_stream_fill(s)) return -3;
	if (s->offset < s->available) {
		DWORD amount = s->available - s->offset;
		if (amount > (DWORD)length) amount = (DWORD)length;
		memcpy(bytes->data + offset, s->buffer + s->offset, amount);
		s->offset += amount;
		return (int)amount;
	}
	return s->ended ? -1 : -2;
#else
	int *fd = stream == 0 ? &p->stdout_fd : &p->stderr_fd;
	if (*fd < 0) hl_error("The process's output is not piped");
	ssize_t count;
	do { count = read(*fd, bytes->data + offset, (size_t)length); } while (count < 0 && errno == EINTR);
	if (count > 0) return (int)count;
	if (count == 0) return -1;
	if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
	realtime_child_fail(errno);
	return -3;
#endif
}

HL_PRIM int HL_NAME(__child_read_stdout)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) {
	return realtime_child_read(p, bytes, offset, length, 0);
}

HL_PRIM int HL_NAME(__child_read_stderr)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) {
	return realtime_child_read(p, bytes, offset, length, 1);
}

/* Writes what the pipe takes without waiting: how many bytes (0 when it is full), or -1 after a failure. */
HL_PRIM int HL_NAME(__child_write)(realtime_child_process *p, realtime_bytes *bytes, int offset, int length) {
	realtime_child_check(p);
	realtime_bytes_bounds(bytes, offset, length);
	realtime_child_succeed();
#ifdef HL_WIN
	if (!p->stdin_piped) hl_error("The process's input is not piped");
	if (length == 0) return 0;
	EnterCriticalSection(&p->write_mutex);
	if (p->write_close_requested) { LeaveCriticalSection(&p->write_mutex); hl_error("The process's input is closed"); }
	if (p->write_failed) {
		LeaveCriticalSection(&p->write_mutex);
		realtime_child_refuse(REALTIME_CHILD_INPUT_CLOSED, ERROR_BROKEN_PIPE);
		return -1;
	}
	size_t available = p->write_capacity - p->write_length - p->write_inflight;
	size_t accepted = (size_t)length < available ? (size_t)length : available;
	if (accepted != 0) {
		memcpy(p->write_queue + p->write_length, bytes->data + offset, accepted);
		p->write_length += accepted;
		WakeConditionVariable(&p->write_ready);
	}
	LeaveCriticalSection(&p->write_mutex);
	return (int)accepted;
#else
	if (p->stdin_fd < 0) hl_error("The process's input is closed or not piped");
	if (length == 0) return 0;
	/* Suppress SIGPIPE only for this thread/write, preserving the caller's signal policy. */
	sigset_t blocked, previous, pending;
	sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
	if (pthread_sigmask(SIG_BLOCK, &blocked, &previous) != 0) hl_error("Could not block SIGPIPE");
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
	realtime_child_fail(saved);
	return -1;
#endif
}

/* Closes the child's input, so it reads its end; closing it again does nothing. */
HL_PRIM void HL_NAME(__child_close_stdin)(realtime_child_process *p) {
	realtime_child_check(p);
#ifdef HL_WIN
	if (p->write_mutex_ready) {
		EnterCriticalSection(&p->write_mutex);
		p->write_close_requested = true;
		WakeConditionVariable(&p->write_ready);
		LeaveCriticalSection(&p->write_mutex);
	}
#else
	realtime_child_fd_close(&p->stdin_fd);
#endif
}

/* What of `wanted` is known ready without waiting (on POSIX only the exit; the descriptors are polled), or -1 after a
   failure. */
static int realtime_child_ready(realtime_child_process *p, int wanted) {
	int ready = 0;
#ifdef HL_WIN
	for (int i = 0; i < 2; i++) {
		int bit = i == 0 ? REALTIME_CHILD_STDOUT : REALTIME_CHILD_STDERR;
		realtime_child_stream *s = p->out[i];
		if ((wanted & bit) == 0 || s == NULL) continue;
		if (!realtime_child_stream_fill(s)) return -1;
		if (realtime_child_stream_ready(s)) ready |= bit;
	}
	if ((wanted & REALTIME_CHILD_STDIN) && p->stdin_piped) {
		EnterCriticalSection(&p->write_mutex);
		if (p->write_failed || p->write_length + p->write_inflight < p->write_capacity) ready |= REALTIME_CHILD_STDIN;
		LeaveCriticalSection(&p->write_mutex);
	}
	if (wanted & REALTIME_CHILD_EXIT) {
		if (realtime_child_reap(p, 0)) ready |= REALTIME_CHILD_EXIT;
		else if (realtime_child_kind != REALTIME_CHILD_OK) return -1;
	}
#else
	if (wanted & REALTIME_CHILD_EXIT) {
		if (realtime_child_reap(p, false)) ready |= REALTIME_CHILD_EXIT;
		else if (realtime_child_kind != REALTIME_CHILD_OK) return -1;
	}
#endif
	return ready;
}

/*
 * Waits up to `milliseconds` (negative: without limit) for what `wanted` names: output to read (or its end), room to
 * write input, or the exit. Answers what is ready, 0 when the time ran out, -1 after a failure.
 */
HL_PRIM int HL_NAME(__child_wait)(realtime_child_process *p, int wanted, int milliseconds) {
	realtime_child_check(p);
	realtime_child_succeed();
	int ready = realtime_child_ready(p, wanted);
	if (ready != 0) return ready;
#ifdef HL_WIN
	ULONGLONG deadline = milliseconds < 0 ? 0 : GetTickCount64() + (ULONGLONG)milliseconds;
	while (ready == 0) {
		HANDLE handles[4];
		DWORD count = 0;
		for (int i = 0; i < 2; i++) {
			int bit = i == 0 ? REALTIME_CHILD_STDOUT : REALTIME_CHILD_STDERR;
			if ((wanted & bit) && p->out[i] != NULL && p->out[i]->pending) handles[count++] = p->out[i]->event;
		}
		if ((wanted & REALTIME_CHILD_STDIN) && p->stdin_piped) handles[count++] = p->write_space;
		if (wanted & REALTIME_CHILD_EXIT) handles[count++] = p->process;
		DWORD timeout = INFINITE;
		if (milliseconds >= 0) {
			ULONGLONG now = GetTickCount64();
			if (now >= deadline) return 0;
			timeout = (DWORD)(deadline - now);
		}
		if (count == 0) {
			/* Nothing that can become ready: only the time can run out. */
			if (milliseconds < 0) hl_error("A process wait has nothing to wait for");
			Sleep(timeout);
			return 0;
		}
		hl_blocking(true);
		DWORD result = WaitForMultipleObjects(count, handles, FALSE, timeout);
		hl_blocking(false);
		if (result == WAIT_FAILED) { realtime_child_fail(GetLastError()); return -1; }
		if (result == WAIT_TIMEOUT) return 0;
		ready = realtime_child_ready(p, wanted);
	}
	return ready;
#else
	if (ready < 0) return -1;
	int64_t deadline = milliseconds < 0 ? 0 : realtime_child_now_ms() + milliseconds;
	bool exit_wanted = (wanted & REALTIME_CHILD_EXIT) != 0;
	for (;;) {
		int remaining = -1;
		if (milliseconds >= 0) {
			int64_t left = deadline - realtime_child_now_ms();
			if (left <= 0) return 0;
			remaining = left > 0x7fffffff ? 0x7fffffff : (int)left;
		}
#ifdef REALTIME_CHILD_KQUEUE
		int queue = kqueue();
		if (queue < 0) { realtime_child_fail(errno); return -1; }
		struct kevent changes[4], events[4];
		int count = 0;
		if ((wanted & REALTIME_CHILD_STDOUT) && p->stdout_fd >= 0)
			EV_SET(&changes[count++], p->stdout_fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, (void *)(intptr_t)REALTIME_CHILD_STDOUT);
		if ((wanted & REALTIME_CHILD_STDERR) && p->stderr_fd >= 0)
			EV_SET(&changes[count++], p->stderr_fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, (void *)(intptr_t)REALTIME_CHILD_STDERR);
		if ((wanted & REALTIME_CHILD_STDIN) && p->stdin_fd >= 0)
			EV_SET(&changes[count++], p->stdin_fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, (void *)(intptr_t)REALTIME_CHILD_STDIN);
		if (exit_wanted)
			EV_SET(&changes[count++], p->pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, (void *)(intptr_t)REALTIME_CHILD_EXIT);
		if (count == 0) {
			close(queue);
			if (milliseconds < 0) hl_error("A process wait has nothing to wait for");
			usleep((useconds_t)remaining * 1000);
			return 0;
		}
		struct timespec timeout = {remaining / 1000, (long)(remaining % 1000) * 1000000};
		hl_blocking(true);
		int got = kevent(queue, changes, count, events, 4, milliseconds < 0 ? NULL : &timeout);
		hl_blocking(false);
		int saved = errno;
		close(queue);
		if (got < 0) {
			if (saved == EINTR) continue;
			realtime_child_fail(saved); return -1;
		}
		for (int i = 0; i < got; i++) {
			int bit = (int)(intptr_t)events[i].udata;
			if (events[i].flags & EV_ERROR) {
				/* A child that is already gone cannot be watched: it has exited, and reaping says how. */
				if (bit == REALTIME_CHILD_EXIT && events[i].data == ESRCH) continue;
				if (events[i].data != 0) { realtime_child_fail((int)events[i].data); return -1; }
			}
			if (bit != REALTIME_CHILD_EXIT) ready |= bit;
		}
#else
		struct pollfd fds[4];
		int bits[4], count = 0;
		if ((wanted & REALTIME_CHILD_STDOUT) && p->stdout_fd >= 0) {
			fds[count] = (struct pollfd){p->stdout_fd, POLLIN, 0}; bits[count++] = REALTIME_CHILD_STDOUT;
		}
		if ((wanted & REALTIME_CHILD_STDERR) && p->stderr_fd >= 0) {
			fds[count] = (struct pollfd){p->stderr_fd, POLLIN, 0}; bits[count++] = REALTIME_CHILD_STDERR;
		}
		if ((wanted & REALTIME_CHILD_STDIN) && p->stdin_fd >= 0) {
			fds[count] = (struct pollfd){p->stdin_fd, POLLOUT, 0}; bits[count++] = REALTIME_CHILD_STDIN;
		}
		int slice = remaining;
		if (exit_wanted) {
			if (p->exit_fd >= 0) { fds[count] = (struct pollfd){p->exit_fd, POLLIN, 0}; bits[count++] = REALTIME_CHILD_EXIT; }
			/* Without a descriptor for the exit, look again at short intervals. */
			else slice = remaining < 0 || remaining > 10 ? 10 : remaining;
		}
		if (count == 0 && !exit_wanted && milliseconds < 0) hl_error("A process wait has nothing to wait for");
		hl_blocking(true);
		int got = poll(fds, (nfds_t)count, slice);
		hl_blocking(false);
		if (got < 0) {
			if (errno == EINTR) continue;
			realtime_child_fail(errno); return -1;
		}
		for (int i = 0; i < count; i++)
			if (fds[i].revents != 0 && bits[i] != REALTIME_CHILD_EXIT) ready |= bits[i];
#endif
		int known = realtime_child_ready(p, wanted);
		if (known < 0) return -1;
		ready |= known;
		if (ready != 0) return ready;
	}
#endif
}

/* Writes how the child exited to `out` (Int32 kind at 0: 0 a code, 1 a signal; Int32 value at 4), or answers false
   while it runs or after recording a failure to ask. */
HL_PRIM bool HL_NAME(__child_exit_status)(realtime_child_process *p, realtime_bytes *out) {
	realtime_child_check(p);
	if (out == NULL || out->length < 8) hl_error("exit status buffer is too small");
	realtime_child_succeed();
#ifdef HL_WIN
	if (!realtime_child_reap(p, 0)) return false;
#else
	if (!realtime_child_reap(p, false)) return false;
#endif
	int32_t kind = p->exit_kind, value = p->exit_value;
	memcpy(out->data, &kind, 4);
	memcpy(out->data + 4, &value, 4);
	return true;
}

HL_PRIM int HL_NAME(__child_pid)(realtime_child_process *p) {
	realtime_child_check(p);
	return (int)p->pid;
}

/* Asks the child to stop (SIGTERM to it, or its group), or with `force` ends it at once (SIGKILL); Windows ends the
   child and what it started either way. A child that has exited is left as it is. */
HL_PRIM void HL_NAME(__child_signal)(realtime_child_process *p, bool force) {
	realtime_child_check(p);
#ifdef HL_WIN
	(void)force;
	if (realtime_child_reap(p, 0)) return;
	BOOL stopped = p->job != NULL ? TerminateJobObject(p->job, 1) : TerminateProcess(p->process, 1);
	/* A child that exited meanwhile refuses with ERROR_ACCESS_DENIED. */
	if (!stopped && GetLastError() != ERROR_ACCESS_DENIED) hl_error("Could not end process: %d", (int)GetLastError());
#else
	if (realtime_child_reap(p, false)) return;
	if (kill(p->owns_process_group ? -p->process_group : p->pid, force ? SIGKILL : SIGTERM) < 0 && errno != ESRCH)
		hl_error("Could not signal process: %s", hl_to_utf16(strerror(errno)));
#endif
}

/* Releases the child: ends and reaps it when it still runs (unless it was started detached), and closes its pipes. */
HL_PRIM void HL_NAME(__child_close)(realtime_child_process *p) {
	if (p != NULL) realtime_child_cleanup(p);
}

HL_PRIM int HL_NAME(__child_error)(void) {
	return realtime_child_kind;
}

HL_PRIM int HL_NAME(__child_error_code)(void) {
	return realtime_child_code;
}

/* The system's description of the last failure's code. */
HL_PRIM vstring *HL_NAME(__child_error_message)(void) {
#ifdef HL_WIN
	wchar_t *message = NULL;
	DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL, (DWORD)realtime_child_code, 0, (wchar_t *)&message, 0, NULL);
	if (length == 0) return realtime_string_from_utf8("unknown Windows error");
	while (length > 0 && (message[length - 1] == L'\r' || message[length - 1] == L'\n' || message[length - 1] == L'.'))
		length--;
	message[length] = 0;
	vstring *result = realtime_string_of_ustr((const uchar *)message);
	LocalFree(message);
	return result;
#else
	if (realtime_child_code == 0) return realtime_string_from_utf8("the process failed");
	return realtime_string_from_utf8(strerror(realtime_child_code));
#endif
}
