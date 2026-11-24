/* Directory change notifications, as a plain C component with no dependency on the Haxeon runtime or HashLink: the watch
 * loop of `haxeon run --watch` uses it through the runtime's __dir_watch_* natives (native/runtime/dir_watch.c), and
 * NativeKit's nk_file_watch is meant to be built on it later, so the two share one implementation per platform.
 *
 * A wait says that something under a watched directory changed, not what: the caller compares its own snapshot of the
 * tree, so a coarse or missed event costs it only a scan. When changes may have been lost (a kernel queue or buffer
 * overflowed, a new directory could not be watched), the wait says so, and the caller rescans everything.
 *
 * Backends: Windows (ReadDirectoryChangesW) and Linux (inotify). Elsewhere create returns NULL and the caller polls; a
 * macOS backend (FSEvents) would be one more section of haxeon_watch.c behind the same functions.
 *
 * Paths are UTF-8. A watch is used from one thread at a time. */
#ifndef HAXEON_WATCH_H
#define HAXEON_WATCH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct haxeon_watch haxeon_watch;

/** What a wait observed. */
typedef enum haxeon_watch_result {
	/** Nothing changed before the timeout. */
	HAXEON_WATCH_NONE = 0,
	/** Something under a watched directory changed. */
	HAXEON_WATCH_CHANGED = 1,
	/** Changes may have been lost: rescan everything. */
	HAXEON_WATCH_RESCAN = 2
} haxeon_watch_result;

/** A watch with nothing added yet, or NULL where the platform has no backend or it could not start. */
haxeon_watch *haxeon_watch_create(void);

/**
 * Watches the directory at `path` and, when `recursive`, every directory under it, including those created there later
 * (symbolic links are not followed). Returns 0, or -1 when it cannot be watched (a missing directory, the system's watch
 * limit), in which case the caller should poll instead.
 */
int haxeon_watch_add(haxeon_watch *watch, const char *path, int recursive);

/**
 * Leaves the directory at `path`, and everything under it, out of the recursive registrations: directories there stop
 * being watched, and changes there are not reported. Returns 0, or -1 on failure.
 */
int haxeon_watch_exclude(haxeon_watch *watch, const char *path);

/** How many directories the watch follows: each one under a recursive root with inotify, each root on Windows. */
int haxeon_watch_count(const haxeon_watch *watch);

/** Waits up to `timeout_ms` (negative: without limit) for a change, and consumes every change since the last wait. */
haxeon_watch_result haxeon_watch_wait(haxeon_watch *watch, int timeout_ms);

/** Stops watching and frees the watch. */
void haxeon_watch_destroy(haxeon_watch *watch);

/** The backend's name ("inotify", "ReadDirectoryChangesW"), or NULL where there is none. */
const char *haxeon_watch_backend(void);

#ifdef __cplusplus
}
#endif

#endif
