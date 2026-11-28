/* Directory change notifications, as a plain C component with no dependency on the Haxeon runtime or HashLink: std.fs.Watcher
 * uses it through the runtime's __watch_* natives, and the watch loop of `haxeon run --watch` through its __dir_watch_*
 * ones (native/runtime/dir_watch.c).
 *
 * A wait consumes what happened since the last one: each path added, removed or modified, in order (a rename is the old
 * path removed and the new one added). When changes may have been lost (a kernel queue or buffer overflowed, a new
 * directory could not be watched), the wait says so, and the caller compares its own view of the tree again.
 *
 * Backends: Windows (ReadDirectoryChangesW), Linux (inotify) and macOS (FSEvents). Elsewhere create returns NULL.
 *
 * Paths are UTF-8 with '/' separators, reported under the path a directory was added with. A watch is used from one
 * thread at a time, except realtime_watch_wake, which any thread may call. */
#ifndef REALTIME_WATCH_H
#define REALTIME_WATCH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct realtime_watch realtime_watch;

/** What a wait observed. */
typedef enum realtime_watch_result {
	/** Nothing changed before the timeout, or the wait was woken. */
	REALTIME_WATCH_NONE = 0,
	/** Something under a watched directory changed: realtime_watch_changes lists what. */
	REALTIME_WATCH_CHANGED = 1,
	/** Changes may have been lost: compare everything again. realtime_watch_changes lists those that were not. */
	REALTIME_WATCH_RESCAN = 2
} realtime_watch_result;

/** Why a directory could not be watched. */
typedef enum realtime_watch_status {
	REALTIME_WATCH_OK = 0,
	/** Nothing is at the path, or a directory on the way to it is missing. */
	REALTIME_WATCH_NOT_FOUND = 1,
	/** Something other than a directory is at the path. */
	REALTIME_WATCH_NOT_A_DIRECTORY = 2,
	/** The directory cannot be read. */
	REALTIME_WATCH_PERMISSION_DENIED = 3,
	/** The system's limit on watched directories is reached. */
	REALTIME_WATCH_LIMIT = 4,
	/** Any other failure. */
	REALTIME_WATCH_FAILED = 5
} realtime_watch_status;

/** What happened to a path. */
typedef enum realtime_watch_change_kind {
	REALTIME_WATCH_ADDED = 1,
	REALTIME_WATCH_REMOVED = 2,
	REALTIME_WATCH_MODIFIED = 3
} realtime_watch_change_kind;

typedef struct realtime_watch_change {
	realtime_watch_change_kind kind;
	const char *path;
} realtime_watch_change;

/** A watch with nothing added yet, or NULL where the platform has no backend or it could not start. */
realtime_watch *realtime_watch_create(void);

/**
 * Watches the directory at `path` and, when `recursive`, every directory under it, including those created there later
 * (symbolic links are not followed; a subdirectory that cannot be read is skipped). Watching a directory again is no
 * failure.
 */
realtime_watch_status realtime_watch_add(realtime_watch *watch, const char *path, int recursive);

/** Stops watching the directory at `path`, added before, and what it watched under it. Returns 0, or -1 when it was not. */
int realtime_watch_remove(realtime_watch *watch, const char *path);

/**
 * Leaves the directory at `path`, and everything under it, out of the recursive registrations: directories there stop
 * being watched, and changes there are not reported. Returns 0, or -1 on failure.
 */
int realtime_watch_exclude(realtime_watch *watch, const char *path);

/** How many directories the watch follows: each one under a recursive root with inotify, each root elsewhere. */
int realtime_watch_count(const realtime_watch *watch);

/** Waits up to `timeout_ms` (negative: without limit) for a change, and consumes every change since the last wait. */
realtime_watch_result realtime_watch_wait(realtime_watch *watch, int timeout_ms);

/** The changes the last wait consumed, in order: `*count` of them, valid until the next wait or destroy. */
const realtime_watch_change *realtime_watch_changes(const realtime_watch *watch, int *count);

/** From any thread: makes a wait in progress, or the next one, return now. */
void realtime_watch_wake(realtime_watch *watch);

/** Stops watching and frees the watch. */
void realtime_watch_destroy(realtime_watch *watch);

/** The backend's name ("inotify", "ReadDirectoryChangesW", "FSEvents"), or NULL where there is none. */
const char *realtime_watch_backend(void);

#ifdef __cplusplus
}
#endif

#endif
