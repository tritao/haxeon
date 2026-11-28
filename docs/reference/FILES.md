# Files and directories

`std.fs` reads and writes files and directories by path. Each operation returns a `Result` whose `Err` is a
`FileError`, so no operation throws for a missing file or a refused write:

```haxe
import std.fs.Files;

function loadSettings():Result<String, std.fs.FileError> {
	try Files.createDirectory("out/cache");
	return Files.readText("settings.json");
}
```

Paths are resolved as the operating system resolves them: an absolute path as it is, a relative one against the
working directory, with `..` and symbolic links followed. On the Wasm targets the files are the session's in-memory
filesystem, with the same operations and the same errors.

## Paths

A `Path` is a `String` kept normalized: separators are `/` (a Windows `\` becomes one), repeated separators and `.`
parts are dropped, and only a root keeps its trailing `/`. `..` stays as written. A `String` converts where a `Path` is
expected.

| Call | Result |
| --- | --- |
| `Path.of("a//b/./c/")` | `a/b/c` |
| `path.join("d.txt")` | `a/b/c/d.txt`; joining an absolute path gives that path |
| `path.parent()` | `a/b`; `.` for a single name, null for a root and for `.` |
| `path.name()`, `path.extension()` | `c`, and the text after the name's last dot (`""` when it starts with it) |
| `path.isAbsolute()` | whether it starts at `/`, a drive (`C:/`) or a share (`//server/share`) |

## Operations

| Operation | Does | Fails with |
| --- | --- | --- |
| `read(path)`, `readText(path)` | the file's bytes, or its text as UTF-8 | `NotFound`, `IsADirectory` |
| `write(path, bytes)`, `writeText` | creates the file or replaces what it holds | `IsADirectory`, `NotFound` (no parent) |
| `append(path, bytes)`, `appendText` | adds to the end, creating the file | as `write` |
| `create(path, bytes)` | creates the file only when nothing is there | `AlreadyExists` |
| `writeAtomic(path, bytes)` | replaces the file in one step: a reader or a crash sees the old file or the new one | as `write` |
| `metadata(path)`, `linkMetadata(path)` | kind, size and last modification; `linkMetadata` describes a symbolic link itself | `NotFound` |
| `canonical(path)` | the absolute path it names, every symbolic link resolved: one per entry, to key a cache by file (`Files` only) | `NotFound` |
| `list(path)` | the directory's entries (name and kind), in no particular order | `NotFound`, `NotADirectory` |
| `createDirectory(path)` | makes the directory and its missing parents; succeeds when it exists | `AlreadyExists` (a file is there) |
| `remove(path)` | deletes a file, a link or an empty directory; succeeds when nothing is there | `NotEmpty` |
| `delete(path)` | as `remove`, but fails when nothing is there | `NotFound`, `NotEmpty` |
| `removeTree(path)` | removes a directory and everything beneath it; links are removed, not followed | |
| `rename(path, target)` | moves a file or directory, replacing a file at `target` | `NotFound` |
| `copy(path, target)` | copies a file's bytes | as `read` and `write` |

Every operation can also fail with `PermissionDenied`, or with `Io(code, message)` for anything else the system
reports, with its own code (`errno`, or `GetLastError` on Windows). `error.describe()` gives the failure in a few
words.

`remove` is for "make sure it is gone": there is no need to check that a file exists before removing it, which would
race with other processes and cost a second call.

## Confined to a directory

`Root.open(path)` opens a directory that nothing reached through it can leave. A root has the same operations as
`Files` but `canonical`, as methods, with paths relative to it (`.` is the root itself):

```haxe
import std.fs.Root;

function serve(workspace:String, request:String):Result<String, std.fs.FileError> {
	var root = try Root.open(workspace);
	var text = root.readText(request);
	root.close();
	return text;
}
```

- `..` and absolute paths fail with `EscapesRoot`, as does a symbolic link that leads out of the directory. A link
  that stays inside is followed.
- The kernel resolves each path: `openat2` with `RESOLVE_BENEATH` on Linux 5.6 or later, `O_RESOLVE_BENEATH` on
  macOS. On Windows a path is kept only when it resolved inside the directory, and what an operation creates, deletes
  or renames is named relative to a directory checked that way.
- Where the system has none of these, `Root.open` fails with `Unsupported` rather than resolve paths in a way that
  could leave the directory.
- The root itself cannot be removed or renamed through it (`PermissionDenied`).
- A root holds its directory open until `close`, which a `scoped` binding calls at the end of its scope. Using it
  after that throws.

## Open files

A `FileHandle` reads and writes a file a part at a time, from a position that each read and write moves.
`FileHandle.open(path, mode)` opens one by path as `Files` does; `root.openFile(path, mode)` opens one beneath a root,
confined as the root's other operations are.

| Mode | Opens | Fails with |
| --- | --- | --- |
| `Read` | a file that is there, to read it | `NotFound`, `IsADirectory` |
| `Write` | a file to write from its start: created when missing, emptied when there | `IsADirectory`, `NotFound` (no parent) |
| `Append` | a file to add to: created when missing, and every write goes to its end | as `Write` |
| `ReadWrite` | a file that is there, to read and write it, keeping what it holds | as `Read` |
| `CreateNew` | a new file, to write it; what is there is left as it was | `AlreadyExists` |

```haxe
import std.fs.FileHandle;

function header(path:String):Result<haxe.io.Bytes, std.fs.FileError> {
	scoped var file = try FileHandle.open(path, Read);
	var bytes = haxe.io.Bytes.alloc(16);
	var read = try file.read(bytes);
	return Ok(bytes.sub(0, read));
}
```

- `read(buffer, offset, length)` answers how many bytes it read: fewer than asked is no failure, and 0 is the end of
  the file. `write` writes every byte, or fails.
- `seek(offset, from)` moves from the `Start`, the `Current` position or the `End`, and answers the new position;
  `position()` and `size()` answer without moving. Positions and sizes are `Int64`.
- `setLength(length)` cuts the file or pads it with zero bytes; `sync()` waits until what was written is on the disk.
- `close()` answers a failure the system reports as it closes. A `scoped` binding closes the handle at the end of its
  scope, and the collector closes one that was dropped; using a closed handle throws.
- On Wasm a handle reads and writes a file of the in-memory filesystem; positions are limited to 2 GB there.

## Watching directories

A `Watcher` reports what changes under the directories it watches: inotify on Linux, ReadDirectoryChangesW on Windows,
FSEvents on macOS. Elsewhere, and on Wasm, `Watcher.open()` is `Err(Unsupported)`.

```haxe
import std.fs.Watcher;

function follow(directory:String):Result<Void, std.fs.FileError> {
	scoped var watcher = try Watcher.open();
	_ = try watcher.add(directory, true);
	for (event in watcher.wait(5))
		switch event {
			case Changed(path, kind): trace('$path: $kind');
			case Rescan: trace("changes were lost; compare the tree again");
		}
	return Ok();
}
```

| Call | Does | Fails with |
| --- | --- | --- |
| `add(path, recursive)` | watches a directory, with every directory under it when `recursive`, those created later included | `NotFound`, `NotADirectory`, `PermissionDenied`, `Io` (the system's limit) |
| `remove(path)` | stops watching a directory added before, and what it watched under it | `NotFound` |
| `exclude(path)` | leaves a subtree out of the recursive registrations | `Io` (no memory) |
| `wait(seconds)` | the changes since the last wait, in order: `Changed(path, kind)` (`Added`, `Removed`, `Modified`), and `Rescan` when some were lost | |
| `wake()` | from any thread, makes a wait in progress return now | |

- A path is reported under the path its directory was added with. A rename is the old path `Removed` and the new one
  `Added`; a directory created under a recursive one is `Added`, then what was already in it when its own watch began.
- Links are not followed, and a subdirectory that cannot be read is skipped.
- A watcher is used from one thread at a time, but `wake`: an app with an event loop waits on a thread of its own, as
  the platform package's `FileWatch` does. Close it when no wait is in progress.

## Not yet

- The working directory: `Sys` still provides it.
- Forms returning `Future<Result<T, FileError>>`, for code on a UI thread.
