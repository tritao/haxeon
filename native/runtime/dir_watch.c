/* The watch loop's natives (`haxeon run --watch`, tools.DirectoryWatcher) over the directory watcher component,
   native/watch/haxeon_watch.h. The path is a Haxe String and the watch an opaque handle, so the CLI binds these the same way
   whether stock Haxe or Haxeon built it. */
#include "../watch/haxeon_watch.h"

/* A watch for directories added next, or null where the platform has no backend (the caller then polls). */
HL_PRIM haxeon_watch *HL_NAME(__dir_watch_open)(void) {
	return haxeon_watch_create();
}

/* Watches a directory, and everything under it when `recursive`; false when it cannot be watched. */
HL_PRIM bool HL_NAME(__dir_watch_add)(haxeon_watch *watch, vstring *path, bool recursive) {
	const char *utf8 = realtime_string_utf8(path);
	return watch != NULL && utf8 != NULL && haxeon_watch_add(watch, utf8, recursive ? 1 : 0) == 0;
}

/* Leaves a directory and everything under it out of the recursive registrations. */
HL_PRIM bool HL_NAME(__dir_watch_exclude)(haxeon_watch *watch, vstring *path) {
	const char *utf8 = realtime_string_utf8(path);
	return watch != NULL && utf8 != NULL && haxeon_watch_exclude(watch, utf8) == 0;
}

/* How many directories the watch follows, which the watch loop reports. */
HL_PRIM int HL_NAME(__dir_watch_count)(haxeon_watch *watch) {
	return haxeon_watch_count(watch);
}

/* Waits up to `milliseconds` for a change: 0 when none, 1 when something changed, 2 when changes may have been lost,
   which the caller treats as "rescan everything". */
HL_PRIM int HL_NAME(__dir_watch_wait)(haxeon_watch *watch, int milliseconds) {
	if (watch == NULL) return HAXEON_WATCH_RESCAN;
	hl_blocking(true);
	haxeon_watch_result result = haxeon_watch_wait(watch, milliseconds);
	hl_blocking(false);
	return (int)result;
}

HL_PRIM void HL_NAME(__dir_watch_close)(haxeon_watch *watch) {
	haxeon_watch_destroy(watch);
}

DEFINE_PRIM(_ABSTRACT(haxeon_watch),__dir_watch_open,_NO_ARG);
DEFINE_PRIM(_BOOL,__dir_watch_add,_ABSTRACT(haxeon_watch) _STRING _BOOL);
DEFINE_PRIM(_BOOL,__dir_watch_exclude,_ABSTRACT(haxeon_watch) _STRING);
DEFINE_PRIM(_I32,__dir_watch_count,_ABSTRACT(haxeon_watch));
DEFINE_PRIM(_I32,__dir_watch_wait,_ABSTRACT(haxeon_watch) _I32);
DEFINE_PRIM(_VOID,__dir_watch_close,_ABSTRACT(haxeon_watch));
