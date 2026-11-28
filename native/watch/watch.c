/* Directory change notifications (watch.h): one section per backend, each defining the functions the header declares, over
 * the excluded subtrees and the change lists they share. */
#include "watch.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

/* Subtrees left out of recursive registrations, by path with '/' separators and no trailing one. */
typedef struct {
	char **paths;
	int count;
} realtime_watch_excludes;

/* A wait's changes, each path owned by the list. Past REALTIME_WATCH_MAX_CHANGES the rest are dropped and the wait says
 * RESCAN. */
typedef struct {
	realtime_watch_change *items;
	int count;
	int capacity;
	int overflowed;
} realtime_watch_list;

#define REALTIME_WATCH_MAX_CHANGES 65536

/* `path` with '/' separators and no trailing separator, newly allocated, or NULL. */
static char *realtime_watch_normalized(const char *path) {
	size_t length = strlen(path);
	char *result = (char *)malloc(length + 1);
	if (result == NULL) return NULL;
	for (size_t index = 0; index <= length; index++) result[index] = path[index] == '\\' ? '/' : path[index];
	while (length > 1 && result[length - 1] == '/') result[--length] = 0;
	return result;
}

static int realtime_watch_same_char(char left, char right) {
#ifdef _WIN32
	/* Windows paths are case-insensitive; ASCII folding covers the names a build tree has. */
	if (left >= 'A' && left <= 'Z') left = (char)(left - 'A' + 'a');
	if (right >= 'A' && right <= 'Z') right = (char)(right - 'A' + 'a');
#endif
	return left == right;
}

/* Whether the normalized `path` is `root` or under it. */
static int realtime_watch_within(const char *root, const char *path) {
	size_t index = 0;
	for (; root[index] != 0; index++)
		if (!realtime_watch_same_char(root[index], path[index])) return 0;
	return path[index] == 0 || path[index] == '/';
}

#if defined(_WIN32) || defined(__APPLE__)
/* Whether the normalized `path` is `root` itself. */
static int realtime_watch_same(const char *root, const char *path) {
	return realtime_watch_within(root, path) && strlen(root) == strlen(path);
}
#endif

static int realtime_watch_excluded(const realtime_watch_excludes *excludes, const char *path) {
	for (int index = 0; index < excludes->count; index++)
		if (realtime_watch_within(excludes->paths[index], path)) return 1;
	return 0;
}

/* Records `path` as excluded; its normalized copy, owned by `excludes`, or NULL. */
static const char *realtime_watch_add_exclude(realtime_watch_excludes *excludes, const char *path) {
	char *normalized = realtime_watch_normalized(path);
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

static void realtime_watch_free_excludes(realtime_watch_excludes *excludes) {
	for (int index = 0; index < excludes->count; index++) free(excludes->paths[index]);
	free(excludes->paths);
}

/* `directory` + '/' + `name`, newly allocated, or NULL. */
static char *realtime_watch_join(const char *directory, const char *name) {
	size_t size = strlen(directory) + strlen(name) + 2;
	char *result = (char *)malloc(size);
	if (result != NULL) snprintf(result, size, "%s/%s", directory, name);
	return result;
}

static void realtime_watch_clear(realtime_watch_list *list) {
	for (int index = 0; index < list->count; index++) free((char *)list->items[index].path);
	list->count = 0;
	list->overflowed = 0;
}

static void realtime_watch_free_list(realtime_watch_list *list) {
	realtime_watch_clear(list);
	free(list->items);
	list->items = NULL;
	list->capacity = 0;
}

/* Appends `kind` of `path`, which the list takes (NULL: no memory). A repeat of the last change is one change, as one write
 * is several of the kernel's notifications. Returns 0, or -1 when the change was dropped. */
static int realtime_watch_push(realtime_watch_list *list, realtime_watch_change_kind kind, char *path) {
	if (path == NULL) {
		list->overflowed = 1;
		return -1;
	}
	if (list->count > 0 && list->items[list->count - 1].kind == kind
		&& strcmp(list->items[list->count - 1].path, path) == 0) {
		free(path);
		return 0;
	}
	if (list->count >= REALTIME_WATCH_MAX_CHANGES) {
		free(path);
		list->overflowed = 1;
		return -1;
	}
	if (list->count == list->capacity) {
		int capacity = list->capacity == 0 ? 64 : list->capacity * 2;
		realtime_watch_change *items = (realtime_watch_change *)realloc(list->items,
			sizeof(realtime_watch_change) * (size_t)capacity);
		if (items == NULL) {
			free(path);
			list->overflowed = 1;
			return -1;
		}
		list->items = items;
		list->capacity = capacity;
	}
	list->items[list->count].kind = kind;
	list->items[list->count].path = path;
	list->count++;
	return 0;
}

#if defined(_WIN32)
#include <windows.h>

/* ReadDirectoryChangesW watches a directory and, when recursive, its whole subtree with one handle: a root is one entry.
 * Each entry's notifications are read for the paths they name, leaving out the excluded subtrees. The last of the events
 * a wait waits on is the watch's wake event. */
#define REALTIME_WATCH_MAX 63

typedef struct {
	char *path; /* normalized UTF-8 */
	HANDLE directory;
	HANDLE event;
	OVERLAPPED overlapped;
	BOOL recursive;
	DWORD buffer[4096];
} realtime_watch_entry;

struct realtime_watch {
	int count;
	realtime_watch_entry *entries[REALTIME_WATCH_MAX];
	realtime_watch_excludes excludes;
	realtime_watch_list changes;
	HANDLE wake;
};

static BOOL realtime_watch_issue(realtime_watch_entry *entry) {
	ResetEvent(entry->event);
	memset(&entry->overlapped, 0, sizeof(entry->overlapped));
	entry->overlapped.hEvent = entry->event;
	return ReadDirectoryChangesW(entry->directory, entry->buffer, sizeof(entry->buffer), entry->recursive,
		FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE |
			FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_ATTRIBUTES,
		NULL, &entry->overlapped, NULL);
}

static WCHAR *realtime_watch_wide(const char *utf8) {
	int length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
	if (length <= 0) return NULL;
	WCHAR *wide = (WCHAR *)malloc(sizeof(WCHAR) * (size_t)length);
	if (wide != NULL) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, length);
	return wide;
}

/* `length` UTF-16 units as UTF-8, newly allocated, or NULL. */
static char *realtime_watch_utf8(const WCHAR *wide, int length) {
	int size = WideCharToMultiByte(CP_UTF8, 0, wide, length, NULL, 0, NULL, NULL);
	if (size < 0) return NULL;
	char *utf8 = (char *)malloc((size_t)size + 1);
	if (utf8 == NULL) return NULL;
	WideCharToMultiByte(CP_UTF8, 0, wide, length, utf8, size, NULL, NULL);
	utf8[size] = 0;
	return utf8;
}

static realtime_watch_status realtime_watch_status_of(DWORD error) {
	switch (error) {
	case ERROR_FILE_NOT_FOUND:
	case ERROR_PATH_NOT_FOUND:
	case ERROR_INVALID_NAME:
	case ERROR_BAD_NETPATH:
	case ERROR_BAD_NET_NAME:
		return REALTIME_WATCH_NOT_FOUND;
	case ERROR_DIRECTORY:
		return REALTIME_WATCH_NOT_A_DIRECTORY;
	case ERROR_ACCESS_DENIED:
	case ERROR_SHARING_VIOLATION:
		return REALTIME_WATCH_PERMISSION_DENIED;
	default:
		return REALTIME_WATCH_FAILED;
	}
}

const char *realtime_watch_backend(void) {
	return "ReadDirectoryChangesW";
}

realtime_watch *realtime_watch_create(void) {
	realtime_watch *watch = (realtime_watch *)calloc(1, sizeof(realtime_watch));
	if (watch == NULL) return NULL;
	watch->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
	if (watch->wake == NULL) {
		free(watch);
		return NULL;
	}
	return watch;
}

static void realtime_watch_close_entry(realtime_watch_entry *entry) {
	CancelIoEx(entry->directory, &entry->overlapped);
	/* The kernel may still write into the buffer until the cancelled request completes. */
	DWORD bytes = 0;
	GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, TRUE);
	CloseHandle(entry->directory);
	CloseHandle(entry->event);
	free(entry->path);
	free(entry);
}

realtime_watch_status realtime_watch_add(realtime_watch *watch, const char *path, int recursive) {
	if (watch == NULL || path == NULL) return REALTIME_WATCH_FAILED;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return REALTIME_WATCH_FAILED;
	for (int index = 0; index < watch->count; index++)
		if (realtime_watch_same(watch->entries[index]->path, normalized) && (watch->entries[index]->recursive || !recursive)) {
			free(normalized);
			return REALTIME_WATCH_OK;
		}
	WCHAR *wide = realtime_watch_wide(path);
	if (wide == NULL) {
		free(normalized);
		return REALTIME_WATCH_FAILED;
	}
	DWORD attributes = GetFileAttributesW(wide);
	realtime_watch_status status = attributes == INVALID_FILE_ATTRIBUTES ? realtime_watch_status_of(GetLastError())
		: (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ? REALTIME_WATCH_NOT_A_DIRECTORY
		: watch->count >= REALTIME_WATCH_MAX ? REALTIME_WATCH_LIMIT
		: REALTIME_WATCH_OK;
	HANDLE directory = INVALID_HANDLE_VALUE;
	if (status == REALTIME_WATCH_OK) {
		directory = CreateFileW(wide, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
			OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
		if (directory == INVALID_HANDLE_VALUE) status = realtime_watch_status_of(GetLastError());
	}
	free(wide);
	if (status != REALTIME_WATCH_OK) {
		free(normalized);
		return status;
	}
	realtime_watch_entry *entry = (realtime_watch_entry *)calloc(1, sizeof(realtime_watch_entry));
	if (entry == NULL) {
		free(normalized);
		CloseHandle(directory);
		return REALTIME_WATCH_FAILED;
	}
	entry->path = normalized;
	entry->directory = directory;
	entry->recursive = recursive ? TRUE : FALSE;
	entry->event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (entry->event == NULL || !realtime_watch_issue(entry)) {
		DWORD error = GetLastError();
		if (entry->event != NULL) CloseHandle(entry->event);
		CloseHandle(directory);
		free(entry->path);
		free(entry);
		return realtime_watch_status_of(error);
	}
	/* A wider registration of the same directory replaces the narrower one. */
	for (int index = 0; index < watch->count; index++)
		if (realtime_watch_same(watch->entries[index]->path, normalized)) {
			realtime_watch_close_entry(watch->entries[index]);
			watch->entries[index] = entry;
			return REALTIME_WATCH_OK;
		}
	watch->entries[watch->count++] = entry;
	return REALTIME_WATCH_OK;
}

int realtime_watch_remove(realtime_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return -1;
	int removed = -1;
	for (int index = 0; index < watch->count;)
		if (realtime_watch_within(normalized, watch->entries[index]->path)) {
			realtime_watch_close_entry(watch->entries[index]);
			watch->entries[index] = watch->entries[--watch->count];
			removed = 0;
		} else
			index++;
	free(normalized);
	return removed;
}

int realtime_watch_exclude(realtime_watch *watch, const char *path) {
	/* The roots keep watching their whole subtree; what is excluded is left out when their notifications are read. */
	return watch != NULL && path != NULL && realtime_watch_add_exclude(&watch->excludes, path) != NULL ? 0 : -1;
}

int realtime_watch_count(const realtime_watch *watch) {
	return watch == NULL ? 0 : watch->count;
}

/* Adds what the notifications `bytes` of `entry` name, but the excluded subtrees, to the wait's changes. */
static void realtime_watch_collect(realtime_watch *watch, const realtime_watch_entry *entry, DWORD bytes) {
	const unsigned char *at = (const unsigned char *)entry->buffer, *end = at + bytes;
	while (at + sizeof(FILE_NOTIFY_INFORMATION) <= end) {
		const FILE_NOTIFY_INFORMATION *info = (const FILE_NOTIFY_INFORMATION *)at;
		realtime_watch_change_kind kind = info->Action == FILE_ACTION_ADDED || info->Action == FILE_ACTION_RENAMED_NEW_NAME
			? REALTIME_WATCH_ADDED
			: info->Action == FILE_ACTION_REMOVED || info->Action == FILE_ACTION_RENAMED_OLD_NAME ? REALTIME_WATCH_REMOVED
			: REALTIME_WATCH_MODIFIED;
		char *name = realtime_watch_utf8(info->FileName, (int)(info->FileNameLength / sizeof(WCHAR)));
		char *joined = name == NULL ? NULL : realtime_watch_join(entry->path, name);
		char *path = joined == NULL ? NULL : realtime_watch_normalized(joined);
		free(joined);
		free(name);
		if (path != NULL && realtime_watch_excluded(&watch->excludes, path))
			free(path);
		else
			realtime_watch_push(&watch->changes, kind, path);
		if (info->NextEntryOffset == 0) break;
		at += info->NextEntryOffset;
	}
}

realtime_watch_result realtime_watch_wait(realtime_watch *watch, int timeout_ms) {
	if (watch == NULL) return REALTIME_WATCH_RESCAN;
	realtime_watch_clear(&watch->changes);
	HANDLE events[REALTIME_WATCH_MAX + 1];
	for (int index = 0; index < watch->count; index++) events[index] = watch->entries[index]->event;
	events[watch->count] = watch->wake;
	DWORD waited = WaitForMultipleObjects((DWORD)watch->count + 1, events, FALSE,
		timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
	if (waited == WAIT_TIMEOUT || waited == WAIT_OBJECT_0 + (DWORD)watch->count) return REALTIME_WATCH_NONE;
	if (waited > WAIT_OBJECT_0 + (DWORD)watch->count) return REALTIME_WATCH_RESCAN;
	int rescan = 0;
	/* Every signalled entry is consumed and armed again, so one wait reports all that changed since the last. */
	for (int index = 0; index < watch->count; index++) {
		realtime_watch_entry *entry = watch->entries[index];
		if (WaitForSingleObject(entry->event, 0) != WAIT_OBJECT_0) continue;
		DWORD bytes = 0;
		/* No bytes: the buffer overflowed and the changes were dropped. A failure: the directory went away. */
		if (!GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, FALSE) || bytes == 0)
			rescan = 1;
		else
			realtime_watch_collect(watch, entry, bytes);
		if (!realtime_watch_issue(entry)) rescan = 1;
	}
	if (rescan || watch->changes.overflowed) return REALTIME_WATCH_RESCAN;
	return watch->changes.count > 0 ? REALTIME_WATCH_CHANGED : REALTIME_WATCH_NONE;
}

void realtime_watch_wake(realtime_watch *watch) {
	if (watch != NULL) SetEvent(watch->wake);
}

void realtime_watch_destroy(realtime_watch *watch) {
	if (watch == NULL) return;
	for (int index = 0; index < watch->count; index++) realtime_watch_close_entry(watch->entries[index]);
	realtime_watch_free_excludes(&watch->excludes);
	realtime_watch_free_list(&watch->changes);
	CloseHandle(watch->wake);
	free(watch);
}

#elif defined(__linux__)
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

/* inotify watches one directory, not what is under it: a recursive root gets a watch for each directory below it, and one
 * for each directory created or moved there later. Watch descriptors are small and increasing, so the directories are kept
 * by descriptor; a slot is freed when the kernel drops its watch (IN_IGNORED: the directory went away) or it is excluded.
 * An eventfd beside the inotify descriptor wakes a wait. */
typedef struct {
	char *path; /* normalized */
	int recursive;
	/* Added as itself, not found under a recursive root: its own removal is reported. */
	int root;
} realtime_watch_entry;

struct realtime_watch {
	int fd;
	int wake;
	int count;
	int capacity;
	realtime_watch_entry *entries; /* by watch descriptor */
	realtime_watch_excludes excludes;
	realtime_watch_list changes;
};

#define REALTIME_WATCH_EVENTS (IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO \
	| IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)

const char *realtime_watch_backend(void) {
	return "inotify";
}

realtime_watch *realtime_watch_create(void) {
	int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (fd < 0) return NULL;
	int wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	realtime_watch *watch = wake < 0 ? NULL : (realtime_watch *)calloc(1, sizeof(realtime_watch));
	if (watch == NULL) {
		if (wake >= 0) close(wake);
		close(fd);
		return NULL;
	}
	watch->fd = fd;
	watch->wake = wake;
	return watch;
}

static void realtime_watch_forget(realtime_watch *watch, int wd) {
	free(watch->entries[wd].path);
	watch->entries[wd].path = NULL;
	watch->entries[wd].recursive = 0;
	watch->entries[wd].root = 0;
	watch->count--;
}

static realtime_watch_status realtime_watch_status_of(int error) {
	switch (error) {
	case ENOENT:
		return REALTIME_WATCH_NOT_FOUND;
	case ENOTDIR:
		return REALTIME_WATCH_NOT_A_DIRECTORY;
	case EACCES:
	case EPERM:
		return REALTIME_WATCH_PERMISSION_DENIED;
	case ENOSPC:
		return REALTIME_WATCH_LIMIT;
	default:
		return REALTIME_WATCH_FAILED;
	}
}

/* Watches the normalized `path` and, when recursive, every directory below it that is not excluded. A directory under the
 * root that vanished meanwhile, or that cannot be read, is skipped; the root's own failure, or reaching the system's limit,
 * is the answer. With `report`, what is found under `path` is added to it: a directory created after the watch began may
 * hold entries made before its own watch did. */
static realtime_watch_status realtime_watch_tree(realtime_watch *watch, const char *path, int recursive, int root,
	realtime_watch_list *report) {
	if (realtime_watch_excluded(&watch->excludes, path)) return REALTIME_WATCH_OK;
	int wd = inotify_add_watch(watch->fd, path, REALTIME_WATCH_EVENTS);
	if (wd < 0) {
		realtime_watch_status status = realtime_watch_status_of(errno);
		return root || status == REALTIME_WATCH_LIMIT || status == REALTIME_WATCH_FAILED ? status : REALTIME_WATCH_OK;
	}
	if (wd >= watch->capacity) {
		int capacity = watch->capacity == 0 ? 64 : watch->capacity;
		while (capacity <= wd) capacity *= 2;
		realtime_watch_entry *entries = (realtime_watch_entry *)realloc(watch->entries,
			sizeof(realtime_watch_entry) * (size_t)capacity);
		if (entries == NULL) return REALTIME_WATCH_FAILED;
		memset(entries + watch->capacity, 0, sizeof(realtime_watch_entry) * (size_t)(capacity - watch->capacity));
		watch->entries = entries;
		watch->capacity = capacity;
	}
	realtime_watch_entry *entry = &watch->entries[wd];
	/* Watching a directory twice gives its descriptor back: keep the first entry, recursive if either is. */
	if (entry->path == NULL) {
		if ((entry->path = strdup(path)) == NULL) return REALTIME_WATCH_FAILED;
		watch->count++;
	}
	entry->recursive = entry->recursive || recursive;
	entry->root = entry->root || root;
	if (!recursive) return REALTIME_WATCH_OK;
	DIR *directory = opendir(path);
	if (directory == NULL) {
		realtime_watch_status status = realtime_watch_status_of(errno);
		return root && status != REALTIME_WATCH_NOT_FOUND ? status : REALTIME_WATCH_OK;
	}
	realtime_watch_status status = REALTIME_WATCH_OK;
	struct dirent *item;
	while (status == REALTIME_WATCH_OK && (item = readdir(directory)) != NULL) {
		if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
		char *child = realtime_watch_join(path, item->d_name);
		if (child == NULL) {
			status = REALTIME_WATCH_FAILED;
			break;
		}
		/* Symbolic links are not followed, as a walk of the tree would loop on one that points up. */
		struct stat info;
		int is_directory = item->d_type == DT_DIR
			|| (item->d_type == DT_UNKNOWN && lstat(child, &info) == 0 && S_ISDIR(info.st_mode));
		if (report != NULL && !realtime_watch_excluded(&watch->excludes, child))
			realtime_watch_push(report, REALTIME_WATCH_ADDED, strdup(child));
		if (is_directory) status = realtime_watch_tree(watch, child, 1, 0, report);
		free(child);
	}
	closedir(directory);
	return status;
}

realtime_watch_status realtime_watch_add(realtime_watch *watch, const char *path, int recursive) {
	if (watch == NULL || path == NULL) return REALTIME_WATCH_FAILED;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return REALTIME_WATCH_FAILED;
	struct stat info;
	realtime_watch_status status = stat(normalized, &info) != 0 ? realtime_watch_status_of(errno)
		: !S_ISDIR(info.st_mode) ? REALTIME_WATCH_NOT_A_DIRECTORY
		: realtime_watch_tree(watch, normalized, recursive, 1, NULL);
	free(normalized);
	return status;
}

/* Stops watching the normalized `root` and everything under it; whether anything was watched there. */
static int realtime_watch_drop(realtime_watch *watch, const char *root) {
	int dropped = 0;
	for (int wd = 0; wd < watch->capacity; wd++)
		if (watch->entries[wd].path != NULL && realtime_watch_within(root, watch->entries[wd].path)) {
			inotify_rm_watch(watch->fd, wd);
			realtime_watch_forget(watch, wd);
			dropped = 1;
		}
	return dropped;
}

int realtime_watch_remove(realtime_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return -1;
	int dropped = realtime_watch_drop(watch, normalized);
	free(normalized);
	return dropped ? 0 : -1;
}

int realtime_watch_exclude(realtime_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	const char *excluded = realtime_watch_add_exclude(&watch->excludes, path);
	if (excluded == NULL) return -1;
	realtime_watch_drop(watch, excluded);
	return 0;
}

int realtime_watch_count(const realtime_watch *watch) {
	return watch == NULL ? 0 : watch->count;
}

/* Reads one inotify event into the wait's changes; whether changes may have been lost. */
static int realtime_watch_event(realtime_watch *watch, const struct inotify_event *event) {
	/* The kernel's queue overflowed: events were lost. */
	if (event->mask & IN_Q_OVERFLOW) return 1;
	if (event->wd < 0 || event->wd >= watch->capacity || watch->entries[event->wd].path == NULL) return 0;
	realtime_watch_entry *entry = &watch->entries[event->wd];
	if (event->mask & IN_IGNORED) {
		realtime_watch_forget(watch, event->wd);
		return 0;
	}
	if (event->len == 0) {
		/* The directory itself went away: its parent reports that, unless it was added as itself. */
		if ((event->mask & (IN_DELETE_SELF | IN_MOVE_SELF)) && entry->root)
			realtime_watch_push(&watch->changes, REALTIME_WATCH_REMOVED, strdup(entry->path));
		return 0;
	}
	char *child = realtime_watch_join(entry->path, event->name);
	if (child == NULL) return 1;
	if (realtime_watch_excluded(&watch->excludes, child)) {
		free(child);
		return 0;
	}
	int lost = 0;
	/* A directory moved away keeps its watches, under paths that are no longer its: they are dropped, and it is watched
	 * afresh where it lands if that is under a recursive root. */
	if ((event->mask & IN_ISDIR) && (event->mask & IN_MOVED_FROM)) realtime_watch_drop(watch, child);
	realtime_watch_change_kind kind = event->mask & (IN_CREATE | IN_MOVED_TO) ? REALTIME_WATCH_ADDED
		: event->mask & (IN_DELETE | IN_MOVED_FROM) ? REALTIME_WATCH_REMOVED
		: REALTIME_WATCH_MODIFIED;
	int watched = (event->mask & IN_ISDIR) && kind == REALTIME_WATCH_ADDED && entry->recursive;
	char *added = watched ? strdup(child) : NULL;
	realtime_watch_push(&watch->changes, kind, child);
	/* A directory created or moved under a recursive root is watched from now on, and what is already in it is reported
	 * after it. */
	if (watched && (added == NULL || realtime_watch_tree(watch, added, 1, 0, &watch->changes) != REALTIME_WATCH_OK))
		lost = 1;
	free(added);
	return lost;
}

realtime_watch_result realtime_watch_wait(realtime_watch *watch, int timeout_ms) {
	if (watch == NULL) return REALTIME_WATCH_RESCAN;
	realtime_watch_clear(&watch->changes);
	struct pollfd ready[2] = { { watch->fd, POLLIN, 0 }, { watch->wake, POLLIN, 0 } };
	int polled = poll(ready, 2, timeout_ms < 0 ? -1 : timeout_ms);
	if (polled == 0 || (polled < 0 && errno == EINTR)) return REALTIME_WATCH_NONE;
	if (polled < 0) return REALTIME_WATCH_RESCAN;
	if (ready[1].revents & POLLIN) {
		unsigned long long woken;
		ssize_t drained = read(watch->wake, &woken, sizeof(woken));
		(void)drained;
	}
	int lost = 0;
	char buffer[16384] __attribute__((aligned(__alignof__(struct inotify_event))));
	/* Everything queued is consumed, so one wait reports all that changed since the last. */
	for (;;) {
		ssize_t length = read(watch->fd, buffer, sizeof(buffer));
		if (length <= 0) {
			if (length < 0 && errno != EAGAIN && errno != EINTR) lost = 1;
			break;
		}
		for (char *at = buffer; at < buffer + length;) {
			const struct inotify_event *event = (const struct inotify_event *)at;
			at += sizeof(struct inotify_event) + event->len;
			lost |= realtime_watch_event(watch, event);
		}
	}
	if (lost || watch->changes.overflowed) return REALTIME_WATCH_RESCAN;
	return watch->changes.count > 0 ? REALTIME_WATCH_CHANGED : REALTIME_WATCH_NONE;
}

void realtime_watch_wake(realtime_watch *watch) {
	if (watch == NULL) return;
	unsigned long long one = 1;
	ssize_t written = write(watch->wake, &one, sizeof(one));
	(void)written;
}

void realtime_watch_destroy(realtime_watch *watch) {
	if (watch == NULL) return;
	close(watch->fd);
	close(watch->wake);
	for (int index = 0; index < watch->capacity; index++) free(watch->entries[index].path);
	free(watch->entries);
	realtime_watch_free_excludes(&watch->excludes);
	realtime_watch_free_list(&watch->changes);
	free(watch);
}

#elif defined(__APPLE__) && TARGET_OS_OSX
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>

/* FSEvents watches a directory's whole subtree with one stream: a root is one entry, and a directory added without
 * `recursive` keeps only the changes to it and its direct children. Streams call back on the watch's serial queue, which
 * appends to `pending` under the lock; a wait moves `pending` to `changes`. FSEvents names a path with its links resolved
 * (/private/var for /var), so each entry keeps that spelling to report paths under the one it was added with. */
#define REALTIME_WATCH_MAX 64

struct realtime_watch;

typedef struct {
	struct realtime_watch *watch;
	char *path; /* normalized, as added */
	char *real; /* normalized, links resolved */
	int recursive;
	FSEventStreamRef stream;
} realtime_watch_entry;

struct realtime_watch {
	pthread_mutex_t lock;
	pthread_cond_t signal;
	dispatch_queue_t queue;
	int count;
	realtime_watch_entry *entries[REALTIME_WATCH_MAX];
	realtime_watch_excludes excludes;
	/* Under the lock: what the streams reported since the last wait, whether some was lost, and a wake. */
	realtime_watch_list pending;
	int pending_rescan;
	int woken;
	/* The last wait's, read by its caller. */
	realtime_watch_list changes;
};

const char *realtime_watch_backend(void) {
	return "FSEvents";
}

realtime_watch *realtime_watch_create(void) {
	realtime_watch *watch = (realtime_watch *)calloc(1, sizeof(realtime_watch));
	if (watch == NULL) return NULL;
	watch->queue = dispatch_queue_create("realtime.watch", DISPATCH_QUEUE_SERIAL);
	if (watch->queue == NULL) {
		free(watch);
		return NULL;
	}
	pthread_mutex_init(&watch->lock, NULL);
	pthread_cond_init(&watch->signal, NULL);
	return watch;
}

static realtime_watch_status realtime_watch_status_of(int error) {
	switch (error) {
	case ENOENT:
		return REALTIME_WATCH_NOT_FOUND;
	case ENOTDIR:
		return REALTIME_WATCH_NOT_A_DIRECTORY;
	case EACCES:
	case EPERM:
		return REALTIME_WATCH_PERMISSION_DENIED;
	default:
		return REALTIME_WATCH_FAILED;
	}
}

/* The FSEvents path `reported` under the entry's own spelling, newly allocated, or NULL when it is not under the entry. */
static char *realtime_watch_rebased(const realtime_watch_entry *entry, const char *reported) {
	char *normalized = realtime_watch_normalized(reported);
	if (normalized == NULL || !realtime_watch_within(entry->real, normalized)) {
		free(normalized);
		return NULL;
	}
	const char *tail = normalized + strlen(entry->real);
	size_t size = strlen(entry->path) + strlen(tail) + 1;
	char *result = (char *)malloc(size);
	if (result != NULL) snprintf(result, size, "%s%s", entry->path, tail);
	free(normalized);
	return result;
}

/* Whether the normalized `path` is `root` or one of its direct children. */
static int realtime_watch_direct(const char *root, const char *path) {
	if (!realtime_watch_within(root, path)) return 0;
	const char *tail = path + strlen(root);
	return *tail == 0 || strchr(tail + 1, '/') == NULL;
}

static int realtime_watch_exists(const char *path) {
	struct stat info;
	return lstat(path, &info) == 0;
}

static void realtime_watch_callback(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
	const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
	(void)stream;
	(void)ids;
	realtime_watch_entry *entry = (realtime_watch_entry *)info;
	realtime_watch *watch = entry->watch;
	char **reported = (char **)paths;
	const FSEventStreamEventFlags lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
		| kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged;
	const FSEventStreamEventFlags moved = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
		| kFSEventStreamEventFlagItemRenamed;
	const FSEventStreamEventFlags modified = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
		| kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemChangeOwner
		| kFSEventStreamEventFlagItemFinderInfoMod;
	pthread_mutex_lock(&watch->lock);
	for (size_t index = 0; index < count; index++) {
		FSEventStreamEventFlags flag = flags[index];
		if (flag & lost) {
			watch->pending_rescan = 1;
			continue;
		}
		if (flag & kFSEventStreamEventFlagHistoryDone) continue;
		char *path = realtime_watch_rebased(entry, reported[index]);
		if (path == NULL) continue;
		if ((!entry->recursive && !realtime_watch_direct(entry->path, path))
			|| realtime_watch_excluded(&watch->excludes, path)) {
			free(path);
			continue;
		}
		/* FSEvents coalesces what happened to a path into one event's flags: what is there now decides between a creation
		 * and a removal, or the two sides of a rename. */
		int exists = realtime_watch_exists(path);
		if (flag & moved)
			realtime_watch_push(&watch->pending, exists ? REALTIME_WATCH_ADDED : REALTIME_WATCH_REMOVED, strdup(path));
		if ((flag & modified) && exists)
			realtime_watch_push(&watch->pending, REALTIME_WATCH_MODIFIED, path);
		else
			free(path);
	}
	pthread_cond_signal(&watch->signal);
	pthread_mutex_unlock(&watch->lock);
}

static void realtime_watch_nothing(void *context) {
	(void)context;
}

static void realtime_watch_close_entry(realtime_watch_entry *entry) {
	FSEventStreamStop(entry->stream);
	FSEventStreamInvalidate(entry->stream);
	FSEventStreamRelease(entry->stream);
	/* A callback already queued may still run: wait for the queue to pass it before the entry goes. */
	dispatch_sync_f(entry->watch->queue, NULL, realtime_watch_nothing);
	free(entry->path);
	free(entry->real);
	free(entry);
}

realtime_watch_status realtime_watch_add(realtime_watch *watch, const char *path, int recursive) {
	if (watch == NULL || path == NULL) return REALTIME_WATCH_FAILED;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return REALTIME_WATCH_FAILED;
	for (int index = 0; index < watch->count; index++)
		if (realtime_watch_same(watch->entries[index]->path, normalized) && (watch->entries[index]->recursive || !recursive)) {
			free(normalized);
			return REALTIME_WATCH_OK;
		}
	struct stat info;
	char resolved[PATH_MAX];
	realtime_watch_status status = stat(normalized, &info) != 0 ? realtime_watch_status_of(errno)
		: !S_ISDIR(info.st_mode) ? REALTIME_WATCH_NOT_A_DIRECTORY
		: watch->count >= REALTIME_WATCH_MAX ? REALTIME_WATCH_LIMIT
		: realpath(normalized, resolved) == NULL ? realtime_watch_status_of(errno)
		: REALTIME_WATCH_OK;
	realtime_watch_entry *entry = status == REALTIME_WATCH_OK
		? (realtime_watch_entry *)calloc(1, sizeof(realtime_watch_entry)) : NULL;
	if (entry == NULL || (entry->real = realtime_watch_normalized(resolved)) == NULL) {
		free(entry);
		free(normalized);
		return status == REALTIME_WATCH_OK ? REALTIME_WATCH_FAILED : status;
	}
	entry->watch = watch;
	entry->path = normalized;
	entry->recursive = recursive;
	CFStringRef root = CFStringCreateWithCString(NULL, entry->real, kCFStringEncodingUTF8);
	CFArrayRef roots = root == NULL ? NULL : CFArrayCreate(NULL, (const void **)&root, 1, &kCFTypeArrayCallBacks);
	FSEventStreamContext context = { 0, entry, NULL, NULL, NULL };
	entry->stream = roots == NULL ? NULL : FSEventStreamCreate(NULL, realtime_watch_callback, &context, roots,
		kFSEventStreamEventIdSinceNow, 0.05,
		kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot);
	if (roots != NULL) CFRelease(roots);
	if (root != NULL) CFRelease(root);
	if (entry->stream != NULL) {
		FSEventStreamSetDispatchQueue(entry->stream, watch->queue);
		if (!FSEventStreamStart(entry->stream)) {
			FSEventStreamInvalidate(entry->stream);
			FSEventStreamRelease(entry->stream);
			entry->stream = NULL;
		}
	}
	if (entry->stream == NULL) {
		free(entry->path);
		free(entry->real);
		free(entry);
		return REALTIME_WATCH_FAILED;
	}
	pthread_mutex_lock(&watch->lock);
	realtime_watch_entry *narrower = NULL;
	for (int index = 0; index < watch->count && narrower == NULL; index++)
		if (realtime_watch_same(watch->entries[index]->path, normalized)) {
			narrower = watch->entries[index];
			watch->entries[index] = entry;
		}
	if (narrower == NULL) watch->entries[watch->count++] = entry;
	pthread_mutex_unlock(&watch->lock);
	/* A wider registration of the same directory replaces the narrower one. */
	if (narrower != NULL) realtime_watch_close_entry(narrower);
	return REALTIME_WATCH_OK;
}

int realtime_watch_remove(realtime_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	char *normalized = realtime_watch_normalized(path);
	if (normalized == NULL) return -1;
	realtime_watch_entry *removed[REALTIME_WATCH_MAX];
	int count = 0;
	pthread_mutex_lock(&watch->lock);
	for (int index = 0; index < watch->count;)
		if (realtime_watch_within(normalized, watch->entries[index]->path)) {
			removed[count++] = watch->entries[index];
			watch->entries[index] = watch->entries[--watch->count];
		} else
			index++;
	pthread_mutex_unlock(&watch->lock);
	free(normalized);
	for (int index = 0; index < count; index++) realtime_watch_close_entry(removed[index]);
	return count > 0 ? 0 : -1;
}

int realtime_watch_exclude(realtime_watch *watch, const char *path) {
	if (watch == NULL || path == NULL) return -1;
	pthread_mutex_lock(&watch->lock);
	const char *excluded = realtime_watch_add_exclude(&watch->excludes, path);
	pthread_mutex_unlock(&watch->lock);
	return excluded != NULL ? 0 : -1;
}

int realtime_watch_count(const realtime_watch *watch) {
	return watch == NULL ? 0 : watch->count;
}

realtime_watch_result realtime_watch_wait(realtime_watch *watch, int timeout_ms) {
	if (watch == NULL) return REALTIME_WATCH_RESCAN;
	realtime_watch_clear(&watch->changes);
	pthread_mutex_lock(&watch->lock);
	if (timeout_ms != 0) {
		struct timespec deadline = { 0, 0 };
		if (timeout_ms > 0) {
			struct timeval now;
			gettimeofday(&now, NULL);
			long long nanoseconds = (long long)now.tv_usec * 1000 + (long long)(timeout_ms % 1000) * 1000000;
			deadline.tv_sec = now.tv_sec + timeout_ms / 1000 + (time_t)(nanoseconds / 1000000000);
			deadline.tv_nsec = (long)(nanoseconds % 1000000000);
		}
		while (watch->pending.count == 0 && !watch->pending_rescan && !watch->pending.overflowed && !watch->woken) {
			if (timeout_ms < 0)
				pthread_cond_wait(&watch->signal, &watch->lock);
			else if (pthread_cond_timedwait(&watch->signal, &watch->lock, &deadline) != 0)
				break;
		}
	}
	/* The pending changes become the wait's, and the list the wait held, cleared, collects the next ones. */
	realtime_watch_list taken = watch->pending;
	watch->pending = watch->changes;
	watch->changes = taken;
	int rescan = watch->pending_rescan || watch->changes.overflowed;
	watch->pending_rescan = 0;
	watch->woken = 0;
	pthread_mutex_unlock(&watch->lock);
	if (rescan) return REALTIME_WATCH_RESCAN;
	return watch->changes.count > 0 ? REALTIME_WATCH_CHANGED : REALTIME_WATCH_NONE;
}

void realtime_watch_wake(realtime_watch *watch) {
	if (watch == NULL) return;
	pthread_mutex_lock(&watch->lock);
	watch->woken = 1;
	pthread_cond_signal(&watch->signal);
	pthread_mutex_unlock(&watch->lock);
}

void realtime_watch_destroy(realtime_watch *watch) {
	if (watch == NULL) return;
	for (int index = 0; index < watch->count; index++) realtime_watch_close_entry(watch->entries[index]);
	dispatch_release(watch->queue);
	realtime_watch_free_excludes(&watch->excludes);
	realtime_watch_free_list(&watch->pending);
	realtime_watch_free_list(&watch->changes);
	pthread_cond_destroy(&watch->signal);
	pthread_mutex_destroy(&watch->lock);
	free(watch);
}

#else
/* No backend: create returns NULL. */
struct realtime_watch {
	int unused;
};

const char *realtime_watch_backend(void) {
	return NULL;
}

realtime_watch *realtime_watch_create(void) {
	return NULL;
}

realtime_watch_status realtime_watch_add(realtime_watch *watch, const char *path, int recursive) {
	(void)watch;
	(void)path;
	(void)recursive;
	return REALTIME_WATCH_FAILED;
}

int realtime_watch_remove(realtime_watch *watch, const char *path) {
	(void)watch;
	(void)path;
	return -1;
}

int realtime_watch_exclude(realtime_watch *watch, const char *path) {
	(void)watch;
	(void)path;
	return -1;
}

int realtime_watch_count(const realtime_watch *watch) {
	(void)watch;
	return 0;
}

realtime_watch_result realtime_watch_wait(realtime_watch *watch, int timeout_ms) {
	(void)watch;
	(void)timeout_ms;
	return REALTIME_WATCH_RESCAN;
}

void realtime_watch_wake(realtime_watch *watch) {
	(void)watch;
}

void realtime_watch_destroy(realtime_watch *watch) {
	(void)watch;
}
#endif

const realtime_watch_change *realtime_watch_changes(const realtime_watch *watch, int *count) {
#if defined(_WIN32) || defined(__linux__) || (defined(__APPLE__) && TARGET_OS_OSX)
	if (watch != NULL) {
		*count = watch->changes.count;
		return watch->changes.items;
	}
#else
	(void)watch;
#endif
	*count = 0;
	return NULL;
}
