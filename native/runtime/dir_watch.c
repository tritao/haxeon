/* The directory watcher's natives (native/watch/watch.h), in two sets. std.fs.Watcher's (__watch_*) hold the watch in a
   handle the collector closes, and report each change with its reason; the watch loop's (`haxeon run --watch`,
   tools.DirectoryWatcher, __dir_watch_*) only ask whether something changed, and bind the same way whether stock Haxe or
   Haxeon built the CLI, as their watch is an opaque pointer and their path a Haxe String. */
#include "../watch/watch.h"

/* A watch for directories added next, or null where the platform has no backend (the caller then polls). */
HL_PRIM realtime_watch *HL_NAME(__dir_watch_open)(void) {
	return realtime_watch_create();
}

/* Watches a directory, and everything under it when `recursive`; false when it cannot be watched. */
HL_PRIM bool HL_NAME(__dir_watch_add)(realtime_watch *watch, vstring *path, bool recursive) {
	const char *utf8 = realtime_string_utf8(path);
	return watch != NULL && utf8 != NULL && realtime_watch_add(watch, utf8, recursive ? 1 : 0) == REALTIME_WATCH_OK;
}

/* Leaves a directory and everything under it out of the recursive registrations. */
HL_PRIM bool HL_NAME(__dir_watch_exclude)(realtime_watch *watch, vstring *path) {
	const char *utf8 = realtime_string_utf8(path);
	return watch != NULL && utf8 != NULL && realtime_watch_exclude(watch, utf8) == 0;
}

/* How many directories the watch follows, which the watch loop reports. */
HL_PRIM int HL_NAME(__dir_watch_count)(realtime_watch *watch) {
	return realtime_watch_count(watch);
}

/* Waits up to `milliseconds` for a change: 0 when none, 1 when something changed, 2 when changes may have been lost,
   which the caller treats as "rescan everything". */
HL_PRIM int HL_NAME(__dir_watch_wait)(realtime_watch *watch, int milliseconds) {
	if (watch == NULL) return REALTIME_WATCH_RESCAN;
	hl_blocking(true);
	realtime_watch_result result = realtime_watch_wait(watch, milliseconds);
	hl_blocking(false);
	return (int)result;
}

HL_PRIM void HL_NAME(__dir_watch_close)(realtime_watch *watch) {
	realtime_watch_destroy(watch);
}

DEFINE_PRIM(_ABSTRACT(realtime_watch),__dir_watch_open,_NO_ARG);
DEFINE_PRIM(_BOOL,__dir_watch_add,_ABSTRACT(realtime_watch) _STRING _BOOL);
DEFINE_PRIM(_BOOL,__dir_watch_exclude,_ABSTRACT(realtime_watch) _STRING);
DEFINE_PRIM(_I32,__dir_watch_count,_ABSTRACT(realtime_watch));
DEFINE_PRIM(_I32,__dir_watch_wait,_ABSTRACT(realtime_watch) _I32);
DEFINE_PRIM(_VOID,__dir_watch_close,_ABSTRACT(realtime_watch));

/* std.fs.Watcher's watch: closed when the watcher is, or when it is collected. */
typedef struct {
	void (*finalize)( void * );
	realtime_watch *watch;
} realtime_watcher;

static void realtime_watcher_finalize( void *value ) {
	realtime_watcher *watcher = (realtime_watcher *)value;
	realtime_watch *watch = watcher->watch;
	watcher->watch = NULL;
	if( watch != NULL ) realtime_watch_destroy(watch);
}

/* A watcher with nothing added, or null where the platform has no backend. */
HL_PRIM realtime_watcher *HL_NAME(__watch_open)( void ) {
	realtime_watch *watch = realtime_watch_create();
	if( watch == NULL ) return NULL;
	realtime_watcher *watcher = (realtime_watcher *)hl_gc_alloc_finalizer(sizeof(realtime_watcher));
	watcher->finalize = realtime_watcher_finalize;
	watcher->watch = watch;
	return watcher;
}
DEFINE_PRIM(_ABSTRACT(realtime_watcher),__watch_open,_NO_ARG);

/* Watches a directory, and everything under it when `recursive`: a realtime_watch_status, 0 when it is watched. */
HL_PRIM int HL_NAME(__watch_add)( realtime_watcher *watcher, vstring *path, bool recursive ) {
	const char *utf8 = realtime_string_utf8(path);
	if( watcher->watch == NULL || utf8 == NULL ) return REALTIME_WATCH_FAILED;
	return (int)realtime_watch_add(watcher->watch,utf8,recursive ? 1 : 0);
}
DEFINE_PRIM(_I32,__watch_add,_ABSTRACT(realtime_watcher) _STRING _BOOL);

/* Stops watching a directory added before; false when it was not. */
HL_PRIM bool HL_NAME(__watch_remove)( realtime_watcher *watcher, vstring *path ) {
	const char *utf8 = realtime_string_utf8(path);
	return watcher->watch != NULL && utf8 != NULL && realtime_watch_remove(watcher->watch,utf8) == 0;
}
DEFINE_PRIM(_BOOL,__watch_remove,_ABSTRACT(realtime_watcher) _STRING);

/* Leaves a directory and everything under it out of the recursive registrations. */
HL_PRIM bool HL_NAME(__watch_exclude)( realtime_watcher *watcher, vstring *path ) {
	const char *utf8 = realtime_string_utf8(path);
	return watcher->watch != NULL && utf8 != NULL && realtime_watch_exclude(watcher->watch,utf8) == 0;
}
DEFINE_PRIM(_BOOL,__watch_exclude,_ABSTRACT(realtime_watcher) _STRING);

/* Waits up to `milliseconds` (negative: without limit): 0 nothing, 1 changes, 2 changes may have been lost. */
HL_PRIM int HL_NAME(__watch_wait)( realtime_watcher *watcher, int milliseconds ) {
	if( watcher->watch == NULL ) return REALTIME_WATCH_RESCAN;
	hl_blocking(true);
	realtime_watch_result result = realtime_watch_wait(watcher->watch,milliseconds);
	hl_blocking(false);
	return (int)result;
}
DEFINE_PRIM(_I32,__watch_wait,_ABSTRACT(realtime_watcher) _I32);

/* How many changes the last wait consumed. */
HL_PRIM int HL_NAME(__watch_change_count)( realtime_watcher *watcher ) {
	int count = 0;
	if( watcher->watch != NULL ) realtime_watch_changes(watcher->watch,&count);
	return count;
}
DEFINE_PRIM(_I32,__watch_change_count,_ABSTRACT(realtime_watcher));

/* Change `index`'s kind: 1 added, 2 removed, 3 modified. */
HL_PRIM int HL_NAME(__watch_change_kind)( realtime_watcher *watcher, int index ) {
	int count = 0;
	const realtime_watch_change *changes = watcher->watch == NULL ? NULL : realtime_watch_changes(watcher->watch,&count);
	return index >= 0 && index < count ? (int)changes[index].kind : 0;
}
DEFINE_PRIM(_I32,__watch_change_kind,_ABSTRACT(realtime_watcher) _I32);

/* Change `index`'s path. */
HL_PRIM vstring *HL_NAME(__watch_change_path)( realtime_watcher *watcher, int index ) {
	int count = 0;
	const realtime_watch_change *changes = watcher->watch == NULL ? NULL : realtime_watch_changes(watcher->watch,&count);
	return index >= 0 && index < count ? realtime_string_from_utf8(changes[index].path) : NULL;
}
DEFINE_PRIM(_STRING,__watch_change_path,_ABSTRACT(realtime_watcher) _I32);

/* From any thread: makes a wait in progress, or the next one, return. */
HL_PRIM void HL_NAME(__watch_wake)( realtime_watcher *watcher ) {
	realtime_watch *watch = watcher->watch;
	if( watch != NULL ) realtime_watch_wake(watch);
}
DEFINE_PRIM(_VOID,__watch_wake,_ABSTRACT(realtime_watcher));

HL_PRIM void HL_NAME(__watch_close)( realtime_watcher *watcher ) {
	realtime_watcher_finalize(watcher);
}
DEFINE_PRIM(_VOID,__watch_close,_ABSTRACT(realtime_watcher));
