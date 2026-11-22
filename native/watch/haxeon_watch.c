/* Directory change notifications (haxeon_watch.h): one section per backend, each defining the functions the header
 * declares, and the excluded subtrees they share. */
#include "haxeon_watch.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Subtrees left out of recursive registrations, by path with '/' separators and no trailing one. */
typedef struct {
	char **paths;
	int count;
} haxeon_watch_excludes;

/* `path` with '/' separators and no trailing separator, newly allocated, or NULL. */
static char *haxeon_watch_normalized(const char *path) {
	size_t length = strlen(path);
	char *result = (char *)malloc(length + 1);
	if (result == NULL) return NULL;
	for (size_t index = 0; index <= length; index++) result[index] = path[index] == '\\' ? '/' : path[index];
	while (length > 1 && result[length - 1] == '/') result[--length] = 0;
	return result;
}

static int haxeon_watch_same_char(char left, char right) {
#ifdef _WIN32
	/* Windows paths are case-insensitive; ASCII folding covers the names a build tree has. */
	if (left >= 'A' && left <= 'Z') left = (char)(left - 'A' + 'a');
	if (right >= 'A' && right <= 'Z') right = (char)(right - 'A' + 'a');
#endif
	return left == right;
}

/* Whether the normalized `path` is `root` or under it. */
static int haxeon_watch_within(const char *root, const char *path) {
	size_t index = 0;
	for (; root[index] != 0; index++)
		if (!haxeon_watch_same_char(root[index], path[index])) return 0;
	return path[index] == 0 || path[index] == '/';
}

static int haxeon_watch_excluded(const haxeon_watch_excludes *excludes, const char *path) {
	for (int index = 0; index < excludes->count; index++)
		if (haxeon_watch_within(excludes->paths[index], path)) return 1;
	return 0;
}

/* Records `path` as excluded; its normalized copy, owned by `excludes`, or NULL. */
static const char *haxeon_watch_add_exclude(haxeon_watch_excludes *excludes, const char *path) {
	char *normalized = haxeon_watch_normalized(path);
	if (normalized == NULL) return NULL;
	char **paths = (char **)realloc(excludes->paths, sizeof(char *) * (size_t)(excludes->count + 1));
	if (paths == NULL) {
		free(normalized);
		return NULL;
	}
	excludes->paths = paths;
	excludes->paths[excludes->count++] = normalized;
	return normalized;
}

static void haxeon_watch_free_excludes(haxeon_watch_excludes *excludes) {
	for (int index = 0; index < excludes->count; index++) free(excludes->paths[index]);
	free(excludes->paths);
}

/* `directory` + '/' + `name`, newly allocated, or NULL. */
static char *haxeon_watch_join(const char *directory, const char *name) {
	size_t size = strlen(directory) + strlen(name) + 2;
	char *result = (char *)malloc(size);
	if (result != NULL) snprintf(result, size, "%s/%s", directory, name);
	return result;
}

#if defined(_WIN32)
#include <windows.h>

/* ReadDirectoryChangesW watches a directory and, when recursive, its whole subtree with one handle: a root is one entry.
 * Each entry's notifications are read to leave out changes in excluded subtrees. */
#define HAXEON_WATCH_MAX 64

typedef struct {
	char *path; /* normalized UTF-8 */
	HANDLE directory;
	HANDLE event;
	OVERLAPPED overlapped;
	BOOL recursive;
	DWORD buffer[4096];
} haxeon_watch_entry;

struct haxeon_watch {
	int count;
	haxeon_watch_entry *entries[HAXEON_WATCH_MAX];
	haxeon_watch_excludes excludes;
};

static BOOL haxeon_watch_issue(haxeon_watch_entry *entry) {
	ResetEvent(entry->event);
	memset(&entry->overlapped, 0, sizeof(entry->overlapped));
	entry->overlapped.hEvent = entry->event;
	return ReadDirectoryChangesW(entry->directory, entry->buffer, sizeof(entry->buffer), entry->recursive,
		FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE |
			FILE_NOTIFY_CHANGE_CREATION,
		NULL, &entry->overlapped, NULL);
}

static WCHAR *haxeon_watch_wide(const char *utf8) {
	int length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
	if (length <= 0) return NULL;
	WCHAR *wide = (WCHAR *)malloc(sizeof(WCHAR) * (size_t)length);
	if (wide != NULL) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, length);
	return wide;
}

/* `length` UTF-16 units as UTF-8, newly allocated, or NULL. */
static char *haxeon_watch_utf8(const WCHAR *wide, int length) {
	int size = WideCharToMultiByte(CP_UTF8, 0, wide, length, NULL, 0, NULL, NULL);
	if (size < 0) return NULL;
	char *utf8 = (char *)malloc((size_t)size + 1);
	if (utf8 == NULL) return NULL;
	WideCharToMultiByte(CP_UTF8, 0, wide, length, utf8, size, NULL, NULL);
	utf8[size] = 0;
	return utf8;
}

const char *haxeon_watch_backend(void) {
	return "ReadDirectoryChangesW";
}

haxeon_watch *haxeon_watch_create(void) {
	return (haxeon_watch *)calloc(1, sizeof(haxeon_watch));
}

int haxeon_watch_add(haxeon_watch *watch, const char *path, int recursive) {
	if (watch == NULL || path == NULL || watch->count >= HAXEON_WATCH_MAX) return -1;
	WCHAR *wide = haxeon_watch_wide(path);
	if (wide == NULL) return -1;
	HANDLE directory = CreateFileW(wide, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
		OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
	free(wide);
	if (directory == INVALID_HANDLE_VALUE) return -1;
	haxeon_watch_entry *entry = (haxeon_watch_entry *)calloc(1, sizeof(haxeon_watch_entry));
	if (entry == NULL || (entry->path = haxeon_watch_normalized(path)) == NULL) {
		free(entry);
		CloseHandle(directory);
		return -1;
	}
	entry->directory = directory;
	entry->recursive = recursive ? TRUE : FALSE;
	entry->event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (entry->event == NULL || !haxeon_watch_issue(entry)) {
		if (entry->event != NULL) CloseHandle(entry->event);
		CloseHandle(directory);
		free(entry->path);
		free(entry);
		return -1;
	}
	watch->entries[watch->count++] = entry;
	return 0;
}

int haxeon_watch_exclude(haxeon_watch *watch, const char *path) {
	/* The roots keep watching their whole subtree; what is excluded is left out when their notifications are read. */
	return watch != NULL && path != NULL && haxeon_watch_add_exclude(&watch->excludes, path) != NULL ? 0 : -1;
}

int haxeon_watch_count(const haxeon_watch *watch) {
	return watch == NULL ? 0 : watch->count;
}

/* Whether the notifications `bytes` of `entry` name anything outside the excluded subtrees. */
static int haxeon_watch_relevant(const haxeon_watch *watch, const haxeon_watch_entry *entry, DWORD bytes) {
	if (watch->excludes.count == 0) return 1;
	const unsigned char *at = (const unsigned char *)entry->buffer, *end = at + bytes;
	while (at + sizeof(FILE_NOTIFY_INFORMATION) <= end) {
		const FILE_NOTIFY_INFORMATION *info = (const FILE_NOTIFY_INFORMATION *)at;
		char *name = haxeon_watch_utf8(info->FileName, (int)(info->FileNameLength / sizeof(WCHAR)));
		char *joined = name == NULL ? NULL : haxeon_watch_join(entry->path, name);
		char *path = joined == NULL ? NULL : haxeon_watch_normalized(joined);
		int excluded = path != NULL && haxeon_watch_excluded(&watch->excludes, path);
		free(path);
		free(joined);
		free(name);
		if (!excluded) return 1;
		if (info->NextEntryOffset == 0) break;
		at += info->NextEntryOffset;
	}
	return 0;
}

haxeon_watch_result haxeon_watch_wait(haxeon_watch *watch, int timeout_ms) {
	if (watch == NULL || watch->count == 0) return HAXEON_WATCH_RESCAN;
	HANDLE events[HAXEON_WATCH_MAX];
	for (int index = 0; index < watch->count; index++) events[index] = watch->entries[index]->event;
	DWORD waited = WaitForMultipleObjects((DWORD)watch->count, events, FALSE, timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
	if (waited == WAIT_TIMEOUT) return HAXEON_WATCH_NONE;
	if (waited >= WAIT_OBJECT_0 + (DWORD)watch->count) return HAXEON_WATCH_RESCAN;
	haxeon_watch_result result = HAXEON_WATCH_NONE;
	/* Every signalled entry is consumed and armed again, so one wait reports all that changed since the last. */
	for (int index = 0; index < watch->count; index++) {
		haxeon_watch_entry *entry = watch->entries[index];
		if (WaitForSingleObject(entry->event, 0) != WAIT_OBJECT_0) continue;
		DWORD bytes = 0;
		/* No bytes: the buffer overflowed and the changes were dropped. */
		if (!GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, FALSE) || bytes == 0)
			result = HAXEON_WATCH_RESCAN;
		else if (result == HAXEON_WATCH_NONE && haxeon_watch_relevant(watch, entry, bytes))
			result = HAXEON_WATCH_CHANGED;
		if (!haxeon_watch_issue(entry)) result = HAXEON_WATCH_RESCAN;
	}
	return result;
}

void haxeon_watch_destroy(haxeon_watch *watch) {
	if (watch == NULL) return;
	for (int index = 0; index < watch->count; index++) {
		haxeon_watch_entry *entry = watch->entries[index];
		CancelIoEx(entry->directory, &entry->overlapped);
		/* The kernel may still write into the buffer until the cancelled request completes. */
		DWORD bytes = 0;
		GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, TRUE);
		CloseHandle(entry->directory);
		CloseHandle(entry->event);
		free(entry->path);
		free(entry);
	}
	haxeon_watch_free_excludes(&watch->excludes);
	free(watch);
}

#elif defined(__linux__)
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

/* inotify watches one directory, not what is under it: a recursive root gets a watch for each directory below it, and one
 * for each directory created or moved there later. Watch descriptors are small and increasing, so the directories are kept
 * by descriptor; a slot is freed when the kernel drops its watch (IN_IGNORED: the directory went away) or it is excluded. */
typedef struct {
	char *path; /* normalized */
	int recursive;
} haxeon_watch_entry;

struct haxeon_watch {
	int fd;
	int count;
	int capacity;
	haxeon_watch_entry *entries; /* by watch descriptor */
	haxeon_watch_excludes excludes;
};

#define HAXEON_WATCH_EVENTS (IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO \
	| IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)

const char *haxeon_watch_backend(void) {
	return "inotify";
}

haxeon_watch *haxeon_watch_create(void) {
	int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (fd < 0) return NULL;
	haxeon_watch *watch = (haxeon_watch *)calloc(1, sizeof(haxeon_watch));
	if (watch == NULL) {
		close(fd);
		return NULL;
	}
	watch->fd = fd;
	return watch;
}

static void haxeon_watch_forget(haxeon_watch *watch, int wd) {
	free(watch->entries[wd].path);
	watch->entries[wd].path = NULL;
	watch->entries[wd].recursive = 0;
	watch->count--;
}

/* Watches the normalized `path` and, when recursive, every directory below it that is not excluded. -1 when one cannot
 * be watched (the user's inotify limit, say); a directory that vanished meanwhile is no failure. */
static int haxeon_watch_tree(haxeon_watch *watch, const char *path, int recursive) {
	if (haxeon_watch_excluded(&watch->excludes, path)) return 0;
	int wd = inotify_add_watch(watch->fd, path, HAXEON_WATCH_EVENTS);
	if (wd < 0) return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
	if (wd >= watch->capacity) {
		int capacity = watch->capacity == 0 ? 64 : watch->capacity;
		while (capacity <= wd) capacity *= 2;
		haxeon_watch_entry *entries = (haxeon_watch_entry *)realloc(watch->entries,
			sizeof(haxeon_watch_entry) * (size_t)capacity);
		if (entries == NULL) return -1;
		memset(entries + watch->capacity, 0, sizeof(haxeon_watch_entry) * (size_t)(capacity - watch->capacity));
		watch->entries = entries;
		watch->capacity = capacity;
	}
	haxeon_watch_entry *entry = &watch->entries[wd];
	/* Watching a directory twice gives its descriptor back: keep the first entry, recursive if either is. */
	if (entry->path == NULL) {
		if ((entry->path = strdup(path)) == NULL) return -1;
		watch->count++;
	}
	entry->recursive = entry->recursive || recursive;
	if (!recursive) return 0;
	DIR *directory = opendir(path);
	if (directory == NULL) return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
	int status = 0;
	struct dirent *item;
	while (status == 0 && (item = readdir(directory)) != NULL) {
		if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
		char *child = haxeon_watch_join(path, item->d_name);
		if (child == NULL) {
			status = -1;
			break;
		}
		/* Symbolic links are not followed, as a walk of the tree would loop on one that points up. */
		struct stat info;
		int is_directory = item->d_type == DT_DIR
			|| (item->d_type == DT_UNKNOWN && lstat(child, &info) == 0 && S_ISDIR(info.st_mode));
		if (is_directory) status = haxeon_watch_tree(watch, child, 1);
		free(child);
	}
	closedir(directory);
	return status;
}

int haxeon_watch_add(haxeon_watch *watch, const char *path, int recursive) {
	if (watch == NULL || path == NULL) return -1;
	char *normalized = haxeon_watch_normalized(path);
	if (normalized == NULL) return -1;
	/* The root itself must exist: a vanished subdirectory is no failure, a missing root is. */
	struct stat info;
	int status = stat(normalized, &info) == 0 && S_ISDIR(info.st_mode) ? haxeon_watch_tree(watch, normalized, recursive) : -1;
	free(normalized);
	return status;
}

/* Stops watching the normalized `root` and everything under it. */
static void haxeon_watch_drop(haxeon_watch *watch, const char *root) {
	for (int wd = 0; wd < watch->capacity; wd++)
		if (watch->entries[wd].path != NULL && haxeon_watch_within(root, watch->entries[wd].path)) {
			inotify_rm_watch(watch->fd, wd);
			haxeon_watch_forget(watch, wd);
		}
}

int haxeon_watch_exclude(haxeon_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	const char *excluded = haxeon_watch_add_exclude(&watch->excludes, path);
	if (excluded == NULL) return -1;
	haxeon_watch_drop(watch, excluded);
	return 0;
}

int haxeon_watch_count(const haxeon_watch *watch) {
	return watch == NULL ? 0 : watch->count;
}

/* Reads one inotify event of `watch`'s queue into `result`. */
static void haxeon_watch_event(haxeon_watch *watch, const struct inotify_event *event, haxeon_watch_result *result) {
	/* The kernel's queue overflowed: events were lost. */
	if (event->mask & IN_Q_OVERFLOW) {
		*result = HAXEON_WATCH_RESCAN;
		return;
	}
	if (event->wd < 0 || event->wd >= watch->capacity || watch->entries[event->wd].path == NULL) return;
	if (event->mask & IN_IGNORED) {
		haxeon_watch_forget(watch, event->wd);
		return;
	}
	char *child = event->len > 0 ? haxeon_watch_join(watch->entries[event->wd].path, event->name) : NULL;
	if (event->len > 0 && child == NULL) {
		*result = HAXEON_WATCH_RESCAN;
		return;
	}
	if (child != NULL && haxeon_watch_excluded(&watch->excludes, child)) {
		free(child);
		return;
	}
	if (*result == HAXEON_WATCH_NONE) *result = HAXEON_WATCH_CHANGED;
	/* A directory moved away keeps its watches, under paths that are no longer its: they are dropped, and it is watched
	 * afresh where it lands if that is under a recursive root. */
	if (child != NULL && (event->mask & IN_ISDIR) && (event->mask & IN_MOVED_FROM))
		haxeon_watch_drop(watch, child);
	/* A directory created or moved under a recursive root is watched from now on, with what is already in it. */
	if (child != NULL && (event->mask & IN_ISDIR) && (event->mask & (IN_CREATE | IN_MOVED_TO))
		&& watch->entries[event->wd].recursive && haxeon_watch_tree(watch, child, 1) != 0)
		*result = HAXEON_WATCH_RESCAN;
	free(child);
}

haxeon_watch_result haxeon_watch_wait(haxeon_watch *watch, int timeout_ms) {
	if (watch == NULL || watch->count == 0) return HAXEON_WATCH_RESCAN;
	struct pollfd ready = { watch->fd, POLLIN, 0 };
	int polled = poll(&ready, 1, timeout_ms < 0 ? -1 : timeout_ms);
	if (polled == 0 || (polled < 0 && errno == EINTR)) return HAXEON_WATCH_NONE;
	if (polled < 0) return HAXEON_WATCH_RESCAN;
	haxeon_watch_result result = HAXEON_WATCH_NONE;
	char buffer[16384] __attribute__((aligned(__alignof__(struct inotify_event))));
	/* Everything queued is consumed, so one wait reports all that changed since the last. */
	for (;;) {
		ssize_t length = read(watch->fd, buffer, sizeof(buffer));
		if (length <= 0) {
			if (length < 0 && errno != EAGAIN && errno != EINTR) result = HAXEON_WATCH_RESCAN;
			break;
		}
		for (char *at = buffer; at < buffer + length;) {
			const struct inotify_event *event = (const struct inotify_event *)at;
			at += sizeof(struct inotify_event) + event->len;
			haxeon_watch_event(watch, event, &result);
		}
	}
	return result;
}

void haxeon_watch_destroy(haxeon_watch *watch) {
	if (watch == NULL) return;
	close(watch->fd);
	for (int index = 0; index < watch->capacity; index++) free(watch->entries[index].path);
	free(watch->entries);
	haxeon_watch_free_excludes(&watch->excludes);
	free(watch);
}

#else
/* No backend yet (macOS: FSEvents would go here): create returns NULL and the caller polls. */
struct haxeon_watch {
	int unused;
};

const char *haxeon_watch_backend(void) {
	return NULL;
}

haxeon_watch *haxeon_watch_create(void) {
	return NULL;
}

int haxeon_watch_add(haxeon_watch *watch, const char *path, int recursive) {
	(void)watch;
	(void)path;
	(void)recursive;
	return -1;
}

int haxeon_watch_exclude(haxeon_watch *watch, const char *path) {
	(void)watch;
	(void)path;
	return -1;
}

int haxeon_watch_count(const haxeon_watch *watch) {
	(void)watch;
	return 0;
}

haxeon_watch_result haxeon_watch_wait(haxeon_watch *watch, int timeout_ms) {
	(void)watch;
	(void)timeout_ms;
	return HAXEON_WATCH_RESCAN;
}

void haxeon_watch_destroy(haxeon_watch *watch) {
	(void)watch;
}
#endif
