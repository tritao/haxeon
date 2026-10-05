/* Streaming subprocesses use their own handle, leaving blocking hl_process APIs intact. */
#ifndef HL_WIN
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
	int stdin_fd, stdout_fd, stderr_fd;
	int pid, exit_status;
	bool closed, exited;
} realtime_child_process;

#ifndef HL_WIN
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
		if (result == 0) {
			kill(p->pid, SIGKILL);
			do { result = waitpid(p->pid, &status, 0); } while (result < 0 && errno == EINTR);
		}
		if (result == p->pid) p->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
		p->exited = true;
	}
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
	vstring *cwd, varray *keys, varray *values) {
#ifdef HL_WIN
	hl_error("Streaming subprocesses are not yet supported on Windows");
	return NULL;
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
	bool actions_ready = false;
	pid_t pid = -1;
	for (int i = 0; i < 3 && error == 0; i++) if (!realtime_child_pipe(pipes[i])) error = errno;
	/* Only the parent's ends are nonblocking. Child stdio remains ordinary blocking I/O. */
	int parent_ends[3] = {pipes[0][1], pipes[1][0], pipes[2][0]};
	for (int i = 0; i < 3 && error == 0; i++)
		if (fcntl(parent_ends[i], F_SETFL, O_NONBLOCK) < 0) error = errno;
	if (error == 0) { error = posix_spawn_file_actions_init(&actions); actions_ready = error == 0; }
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
	if (error == 0) error = posix_spawnp(&pid, program, &actions, NULL, argv, env);
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
	p->pid = pid; p->exit_status = -1; p->closed = false; p->exited = false;
	return p;
#endif
}

static void realtime_child_check(realtime_child_process *p) {
	if (p == NULL || p->closed) hl_error("Process is closed");
}
static int realtime_child_read(realtime_child_process *p, realtime_bytes *bytes, int offset, int length, bool stderr_stream) {
	realtime_child_check(p);
	realtime_bytes_bounds(bytes, offset, length);
#ifndef HL_WIN
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
#ifndef HL_WIN
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
#ifndef HL_WIN
	realtime_child_fd_close(&p->stdin_fd);
#endif
}
HL_PRIM int HL_NAME(__child_poll_exit)(realtime_child_process *p) {
	realtime_child_check(p);
#ifndef HL_WIN
	return realtime_child_poll(p, false);
#else
	return -1;
#endif
}
HL_PRIM void HL_NAME(__child_cancel)(realtime_child_process *p) {
	realtime_child_check(p);
#ifndef HL_WIN
	if (realtime_child_poll(p, false) < 0 && kill(p->pid, SIGTERM) < 0 && errno != ESRCH) hl_error("Could not cancel process");
#endif
}
HL_PRIM void HL_NAME(__child_close)(realtime_child_process *p) {
#ifndef HL_WIN
	if (p != NULL) realtime_child_cleanup(p);
#endif
}
