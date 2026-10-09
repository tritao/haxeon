/* Host primitives for private state, secure randomness, loopback ports and lifetime locks. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#ifdef HL_WIN
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <wchar.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#include <unistd.h>
#endif

typedef struct realtime_file_lock {
	void (*finalize)(void *);
#ifdef HL_WIN
	HANDLE file;
	OVERLAPPED overlapped;
#else
	int file;
#endif
	bool closed;
} realtime_file_lock;

typedef struct realtime_process_identity {
	void (*finalize)(void *);
#ifdef HL_WIN
	HANDLE process;
#else
	int fd;
#endif
	bool closed;
} realtime_process_identity;

static void realtime_process_identity_close(void *value) {
	realtime_process_identity *handle = value;
	if (handle->closed) return;
#ifdef HL_WIN
	if (handle->process != NULL) CloseHandle(handle->process);
	handle->process = NULL;
#else
	if (handle->fd >= 0) close(handle->fd);
	handle->fd = -1;
#endif
	handle->closed = true;
}

#ifdef HL_WIN
static bool realtime_process_image_matches(HANDLE process, vstring *expected) {
	wchar_t actual[32768], expected_path[32768], actual_path[32768];
	DWORD actual_length = sizeof(actual) / sizeof(actual[0]);
	DWORD expected_length, full_actual_length;
	if (!QueryFullProcessImageNameW(process, 0, actual, &actual_length)) return false;
	const wchar_t *expected_value = (const wchar_t *)realtime_string_data(expected);
	full_actual_length = GetFullPathNameW(actual, sizeof(actual_path) / sizeof(actual_path[0]), actual_path, NULL);
	if (full_actual_length == 0 || full_actual_length >= sizeof(actual_path) / sizeof(actual_path[0])) return false;
	expected_length = GetFullPathNameW(expected_value, sizeof(expected_path) / sizeof(expected_path[0]), expected_path, NULL);
	if (expected_length == 0 || expected_length >= sizeof(expected_path) / sizeof(expected_path[0])) return false;
	for (DWORD index = 0; index < full_actual_length; index++) if (actual_path[index] == L'/') actual_path[index] = L'\\';
	for (DWORD index = 0; index < expected_length; index++) if (expected_path[index] == L'/') expected_path[index] = L'\\';
	return CompareStringOrdinal(actual_path, (int)full_actual_length, expected_path, (int)expected_length, TRUE) == CSTR_EQUAL;
}
#endif

HL_PRIM realtime_process_identity *HL_NAME(__host_process_identity_open)(int pid, vstring *expected_executable) {
#ifdef HL_WIN
	if (pid <= 0 || expected_executable == NULL) return NULL;
	HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, (DWORD)pid);
	if (process == NULL || GetProcessId(process) != (DWORD)pid || !realtime_process_image_matches(process, expected_executable)) {
		if (process != NULL) CloseHandle(process);
		return NULL;
	}
	realtime_process_identity *handle = hl_gc_alloc_finalizer(sizeof(realtime_process_identity));
	memset(handle, 0, sizeof(*handle));
	handle->finalize = realtime_process_identity_close;
	handle->process = process;
	return handle;
#else
	(void)expected_executable;
#if defined(__linux__) && defined(SYS_pidfd_open)
	if (pid <= 0) return NULL;
	int fd = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
	if (fd < 0) {
		if (errno == ESRCH || errno == ENOSYS || errno == EINVAL) return NULL;
		hl_error("Could not open manager process handle: %s", hl_to_utf16(strerror(errno)));
	}
	realtime_process_identity *handle = hl_gc_alloc_finalizer(sizeof(realtime_process_identity));
	memset(handle, 0, sizeof(*handle));
	handle->finalize = realtime_process_identity_close;
	handle->fd = fd;
	return handle;
#else
	(void)pid;
	return NULL;
#endif
#endif
}

HL_PRIM bool HL_NAME(__host_process_identity_terminate)(realtime_process_identity *handle) {
#ifdef HL_WIN
	if (handle == NULL || handle->closed || handle->process == NULL) return false;
	DWORD status = 0;
	if (!GetExitCodeProcess(handle->process, &status)) hl_error("Could not inspect manager process: %d", (int)GetLastError());
	if (status != STILL_ACTIVE) return false;
	if (TerminateProcess(handle->process, 0)) return true;
	DWORD error = GetLastError();
	if (WaitForSingleObject(handle->process, 0) == WAIT_OBJECT_0) return false;
	hl_error("Could not stop manager process: %d", (int)error);
	return false;
#else
#if defined(__linux__) && defined(SYS_pidfd_send_signal)
	if (handle == NULL || handle->closed || handle->fd < 0) return false;
	if (syscall(SYS_pidfd_send_signal, handle->fd, SIGTERM, NULL, 0) == 0) return true;
	if (errno == ESRCH) return false;
	hl_error("Could not stop manager process: %s", hl_to_utf16(strerror(errno)));
	return false;
#else
	(void)handle;
	return false;
#endif
#endif
}

HL_PRIM void HL_NAME(__host_process_identity_close)(realtime_process_identity *handle) {
	if (handle != NULL) realtime_process_identity_close(handle);
}

#ifdef HL_WIN
static bool realtime_host_current_sid(PSID *sid, void **storage) {
	HANDLE token = NULL;
	if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
	DWORD needed = 0;
	GetTokenInformation(token, TokenUser, NULL, 0, &needed);
	if (needed == 0) { CloseHandle(token); return false; }
	*storage = malloc(needed);
	if (*storage == NULL) { CloseHandle(token); SetLastError(ERROR_NOT_ENOUGH_MEMORY); return false; }
	bool result = GetTokenInformation(token, TokenUser, *storage, needed, &needed) != 0;
	CloseHandle(token);
	if (result) *sid = ((TOKEN_USER *)*storage)->User.Sid;
	return result;
}

static bool realtime_host_security_attributes(SECURITY_ATTRIBUTES *attributes,
	SECURITY_DESCRIPTOR *descriptor, ACL **acl, void **sid_storage) {
	PSID sid = NULL;
	if (!realtime_host_current_sid(&sid, sid_storage)) return false;
	DWORD size = sizeof(ACL) + GetLengthSid(sid) + sizeof(ACCESS_ALLOWED_ACE);
	*acl = malloc(size);
	if (*acl == NULL) { free(*sid_storage); *sid_storage = NULL; SetLastError(ERROR_NOT_ENOUGH_MEMORY); return false; }
	if (!InitializeAcl(*acl, size, ACL_REVISION) ||
		!AddAccessAllowedAceEx(*acl, ACL_REVISION,
			OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE, GENERIC_ALL, sid) ||
		!InitializeSecurityDescriptor(descriptor, SECURITY_DESCRIPTOR_REVISION) ||
		!SetSecurityDescriptorDacl(descriptor, TRUE, *acl, FALSE) ||
		!SetSecurityDescriptorControl(descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) {
		free(*acl); free(*sid_storage); *acl = NULL; *sid_storage = NULL; return false;
	}
	attributes->nLength = sizeof(*attributes);
	attributes->lpSecurityDescriptor = descriptor;
	attributes->bInheritHandle = FALSE;
	return true;
}

static bool realtime_host_private_handle(HANDLE file, bool directory) {
	BY_HANDLE_FILE_INFORMATION info;
	if (!GetFileInformationByHandle(file, &info) ||
		(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
		((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory ||
		(!directory && info.nNumberOfLinks != 1)) return false;
	PSID owner = NULL, user = NULL;
	PACL dacl = NULL;
	PSECURITY_DESCRIPTOR security = NULL;
	void *user_storage = NULL;
	DWORD status = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION |
		DACL_SECURITY_INFORMATION, &owner, NULL, &dacl, NULL, &security);
	bool valid = status == ERROR_SUCCESS && owner != NULL && dacl != NULL &&
		realtime_host_current_sid(&user, &user_storage) && EqualSid(owner, user);
	if (valid) {
		for (DWORD index = 0; index < dacl->AceCount; index++) {
			void *raw = NULL;
			if (!GetAce(dacl, index, &raw)) { valid = false; break; }
			ACE_HEADER *header = raw;
			if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { valid = false; break; }
			ACCESS_ALLOWED_ACE *ace = raw;
			if (!EqualSid(&ace->SidStart, user)) { valid = false; break; }
		}
	}
	free(user_storage);
	if (security != NULL) LocalFree(security);
	return valid;
}

static HANDLE realtime_host_open_path(vstring *path, bool directory, DWORD access) {
	DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0);
	return CreateFileW((const wchar_t *)realtime_string_data(path), access,
		FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, flags, NULL);
}

static bool realtime_host_private_path(vstring *path, bool directory) {
	HANDLE file = realtime_host_open_path(path, directory, FILE_READ_ATTRIBUTES | READ_CONTROL);
	if (file == INVALID_HANDLE_VALUE) return false;
	bool result = realtime_host_private_handle(file, directory);
	CloseHandle(file);
	return result;
}
#else
static char *realtime_host_path(vstring *path) { return realtime_utf8_copy(path); }

static bool realtime_host_private_path(vstring *path, bool directory) {
	char *owned = realtime_host_path(path);
	struct stat info;
	bool result = lstat(owned, &info) == 0 && (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode)) &&
		info.st_uid == geteuid() && (info.st_mode & 077) == 0 && (directory || info.st_nlink == 1);
	free(owned);
	return result;
}
#endif

HL_PRIM bool HL_NAME(__host_prepare_private_directory)(vstring *path) {
#ifdef HL_WIN
	SECURITY_ATTRIBUTES attributes = {0};
	SECURITY_DESCRIPTOR descriptor;
	ACL *acl = NULL;
	void *sid_storage = NULL;
	if (!realtime_host_security_attributes(&attributes, &descriptor, &acl, &sid_storage)) return false;
	const wchar_t *value = (const wchar_t *)realtime_string_data(path);
	bool created = CreateDirectoryW(value, &attributes) != 0;
	DWORD error = created ? ERROR_SUCCESS : GetLastError();
	free(acl); free(sid_storage);
	if (!created && error != ERROR_ALREADY_EXISTS) return false;
	return realtime_host_private_path(path, true);
#else
	char *owned = realtime_host_path(path);
	bool created = mkdir(owned, 0700) == 0;
	int error = errno;
	free(owned);
	return (created || error == EEXIST) && realtime_host_private_path(path, true);
#endif
}

HL_PRIM bool HL_NAME(__host_check_private_directory)(vstring *path) {
	return realtime_host_private_path(path, true);
}

HL_PRIM bool HL_NAME(__host_check_private_file)(vstring *path) {
	return realtime_host_private_path(path, false);
}

HL_PRIM vstring *HL_NAME(__host_secure_random_token)(void) {
	unsigned char bytes[32];
#ifdef HL_WIN
	if (BCryptGenRandom(NULL, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
			hl_error("Could not generate a secure random token");
#else
	int fd = open("/dev/urandom", O_RDONLY
#ifdef O_CLOEXEC
		| O_CLOEXEC
#endif
	);
	if (fd < 0) hl_error("Could not open secure random source");
	size_t offset = 0;
	while (offset < sizeof(bytes)) {
		ssize_t count = read(fd, bytes + offset, sizeof(bytes) - offset);
		if (count < 0 && errno == EINTR) continue;
		if (count <= 0) { close(fd); hl_error("Could not read secure random source"); }
		offset += (size_t)count;
	}
	close(fd);
#endif
	static const char hex[] = "0123456789abcdef";
	char output[65];
	for (size_t index = 0; index < sizeof(bytes); index++) {
		output[index * 2] = hex[bytes[index] >> 4];
		output[index * 2 + 1] = hex[bytes[index] & 15];
	}
	output[64] = 0;
	return realtime_string_from_utf8(output);
}

HL_PRIM int HL_NAME(__host_choose_loopback_port)(void) {
#ifdef HL_WIN
	WSADATA data;
	if (WSAStartup(MAKEWORD(2, 2), &data) != 0) hl_error("Could not initialize loopback sockets");
	SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (socket_handle == INVALID_SOCKET) { WSACleanup(); hl_error("Could not create loopback socket"); }
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = 0;
	int address_length = sizeof(address);
	if (bind(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0 ||
		getsockname(socket_handle, (struct sockaddr *)&address, &address_length) != 0) {
		closesocket(socket_handle); WSACleanup(); hl_error("Could not reserve a loopback port");
	}
	int port = (int)ntohs(address.sin_port);
	closesocket(socket_handle);
	WSACleanup();
	if (port == 0) hl_error("Could not select a loopback port");
	return port;
#else
	int socket_handle = socket(AF_INET, SOCK_STREAM, 0);
	if (socket_handle < 0) hl_error("Could not create loopback socket: %s", hl_to_utf16(strerror(errno)));
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = 0;
	socklen_t address_length = sizeof(address);
	if (bind(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0 ||
		getsockname(socket_handle, (struct sockaddr *)&address, &address_length) != 0) {
		int error = errno; close(socket_handle); hl_error("Could not reserve a loopback port: %s", hl_to_utf16(strerror(error)));
	}
	int port = (int)ntohs(address.sin_port);
	close(socket_handle);
	if (port == 0) hl_error("Could not select a loopback port");
	return port;
#endif
}

static void realtime_file_lock_close(void *value) {
	realtime_file_lock *lock = value;
	if (lock->closed) return;
#ifdef HL_WIN
	if (lock->file != INVALID_HANDLE_VALUE) {
		UnlockFileEx(lock->file, 0, MAXDWORD, MAXDWORD, &lock->overlapped);
		CloseHandle(lock->file);
		lock->file = INVALID_HANDLE_VALUE;
	}
#else
	if (lock->file >= 0) { flock(lock->file, LOCK_UN); close(lock->file); lock->file = -1; }
#endif
	lock->closed = true;
}

HL_PRIM realtime_file_lock *HL_NAME(__host_file_lock_acquire)(vstring *path) {
#ifdef HL_WIN
	HANDLE file = CreateFileW((const wchar_t *)realtime_string_data(path), GENERIC_READ | GENERIC_WRITE,
		FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
	if (file == INVALID_HANDLE_VALUE) hl_error("Could not open file lock: %d", (int)GetLastError());
	if (!realtime_host_private_handle(file, false)) { CloseHandle(file); hl_error("Lock path is not a private regular file"); }
	OVERLAPPED overlapped = {0};
	if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &overlapped)) {
		DWORD error = GetLastError();
		CloseHandle(file);
		if (error == ERROR_LOCK_VIOLATION) return NULL;
		hl_error("Could not acquire file lock: %d", (int)error);
	}
	realtime_file_lock *lock = hl_gc_alloc_finalizer(sizeof(realtime_file_lock));
	memset(lock, 0, sizeof(*lock));
	lock->finalize = realtime_file_lock_close; lock->file = file; lock->overlapped = overlapped;
	return lock;
#else
	char *owned = realtime_host_path(path);
	int file = open(owned, O_RDWR | O_CREAT
#ifdef O_NOFOLLOW
		| O_NOFOLLOW
#endif
	, 0600);
	free(owned);
	if (file < 0) hl_error("Could not open file lock: %s", hl_to_utf16(strerror(errno)));
	struct stat info;
	if (fstat(file, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != geteuid() ||
		(info.st_mode & 077) != 0 || info.st_nlink != 1) { close(file); hl_error("Lock path is not a private regular file"); }
	if (flock(file, LOCK_EX | LOCK_NB) != 0) {
		int error = errno; close(file);
		if (error == EWOULDBLOCK || error == EAGAIN) return NULL;
		hl_error("Could not acquire file lock: %s", hl_to_utf16(strerror(error)));
	}
	realtime_file_lock *lock = hl_gc_alloc_finalizer(sizeof(realtime_file_lock));
	memset(lock, 0, sizeof(*lock));
	lock->finalize = realtime_file_lock_close; lock->file = file;
	return lock;
#endif
}

HL_PRIM int HL_NAME(__host_file_lock_descriptor)(realtime_file_lock *lock) {
#ifdef HL_WIN
	(void)lock;
	return -1;
#else
	if (lock == NULL || lock->closed) return -1;
	return lock->file;
#endif
}

HL_PRIM void HL_NAME(__host_guard_inherited_file_lock)(vstring *environment_key) {
#ifndef HL_WIN
	char *key = realtime_utf8_copy(environment_key);
	if (key == NULL) return;
	const char *value = getenv(key);
	free(key);
	if (value == NULL || value[0] == 0) return;
	char *end = NULL;
	long descriptor = strtol(value, &end, 10);
	if (end == value || *end != 0 || descriptor < 0 || descriptor > INT_MAX) return;
	int flags = fcntl((int)descriptor, F_GETFD);
	if (flags >= 0) (void)fcntl((int)descriptor, F_SETFD, flags | FD_CLOEXEC);
#else
	(void)environment_key;
#endif
}

HL_PRIM void HL_NAME(__host_set_private_umask)(void) {
#ifndef HL_WIN
	(void)umask(077);
#endif
}

#ifndef HL_WIN
static volatile sig_atomic_t realtime_host_stop_requested = 0;
static void realtime_host_request_stop(int signal_number) {
	(void)signal_number;
	realtime_host_stop_requested = 1;
}
#endif

HL_PRIM void HL_NAME(__host_install_stop_signals)(void) {
#ifndef HL_WIN
	realtime_host_stop_requested = 0;
	signal(SIGTERM, realtime_host_request_stop);
	signal(SIGINT, realtime_host_request_stop);
#endif
}

HL_PRIM bool HL_NAME(__host_stop_requested)(void) {
#ifdef HL_WIN
	return false;
#else
	return realtime_host_stop_requested != 0;
#endif
}

HL_PRIM void HL_NAME(__host_file_lock_release)(realtime_file_lock *lock) {
	if (lock != NULL) realtime_file_lock_close(lock);
}

HL_PRIM vstring *HL_NAME(__host_regular_file_identity)(vstring *path) {
#ifdef HL_WIN
	HANDLE file = realtime_host_open_path(path, false, FILE_READ_ATTRIBUTES);
	if (file == INVALID_HANDLE_VALUE) return NULL;
	BY_HANDLE_FILE_INFORMATION info;
	bool valid = GetFileInformationByHandle(file, &info) &&
		(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0;
	CloseHandle(file);
	if (!valid) return NULL;
	wchar_t identity[64];
	_snwprintf(identity, 64, L"%08lx:%08lx:%08lx", (unsigned long)info.dwVolumeSerialNumber,
		(unsigned long)info.nFileIndexHigh, (unsigned long)info.nFileIndexLow);
	return realtime_string_of_ustr((const uchar *)identity);
#else
	char *owned = realtime_host_path(path);
	struct stat info;
	bool valid = lstat(owned, &info) == 0 && S_ISREG(info.st_mode);
	free(owned);
	if (!valid) return NULL;
	char identity[96];
	snprintf(identity, sizeof(identity), "%llu:%llu", (unsigned long long)info.st_dev,
		(unsigned long long)info.st_ino);
	return realtime_string_from_utf8(identity);
#endif
}
