# Directory watch: one C component for change notifications (design note)

Status: in the tree for Windows and Linux; macOS polls. NativeKit's watcher is to be ported onto it (below).

`haxeon run --watch` and `--live` wake on a save instead of a polling interval through `native/watch/haxeon_watch.h`: a
plain C component with no dependency on HashLink or the Haxeon runtime. Its API is create, add a directory (recursive or
not), exclude a subtree, count the watched directories, wait with a timeout, and destroy. A wait answers *none*,
*changed* or *rescan*: it says that something under a watched directory changed, not what, since the watch loop compares
its own snapshot of the tree; *rescan* says changes may have been lost and the loop should take a full snapshot.

Backends, one section of `native/watch/haxeon_watch.c` each:

- **Linux, inotify.** One watch per directory: a recursive root gets one for each directory below it (symbolic links are
  not followed), directories created or moved in later get theirs when their event arrives, a directory moved away loses
  its watches, and the kernel's IN_IGNORED frees the slot of one that went away. `IN_Q_OVERFLOW`, or a new directory that
  cannot be watched, answers *rescan*.
- **Windows, ReadDirectoryChangesW.** One handle per root covers its subtree. A notification buffer with no bytes (it
  overflowed) answers *rescan*; excluded subtrees are left out by reading the notified names.
- **macOS: none yet.** Create returns NULL and the loop polls every 0.35 s (`WatchRun.POLL_SECONDS`). An FSEvents backend
  is one more section behind the same functions.

The runtime's `__dir_watch_*` natives (`native/runtime/dir_watch.c`) are thin wrappers that take the path as a Haxe String
and mark the wait as blocking for the collector; `tools.DirectoryWatcher` binds them the same way whether stock Haxe or
Haxeon built the CLI. The watch loop excludes the project's output directory, whose writes are never edits, and at
`-v detailed` says which it does: `watching N directories (inotify)` or `polling every 0.35 s`.

On Linux, with `haxeon-aot`, a save starts its rebuild about 35 ms later against about 550 ms when polling, a file in a
directory created after the watch started included.

## NativeKit

NativeKit (`vendor/nativekit`) has a watcher of its own behind `nk_file_watch_*` (C++: `src/core/file_watch.cpp`, an
inotify backend and a ReadDirectoryChangesW one), which reports per-path events through NativeKit's event queue and needs
its runtime (`nk_init`, the UI thread); it cannot be linked into the compiler's CLI without NativeKit's GUI dependencies.
The plan is one implementation: NativeKit ports `nk_file_watch` onto this C core, extended where it needs more than a
change/rescan answer (the changed paths and kinds, moves paired by cookie, a background walk of large trees, its
readiness event), and the FSEvents backend is written once, here.
