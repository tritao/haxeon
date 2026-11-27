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

## Not yet

- Open files (streams, seeking) and the working directory: `sys.io.File` and `Sys` still provide them.
- `Root`, a directory that `..` and symbolic links cannot leave, for code that serves files to someone it does not
  trust.
- Forms returning `Future<Result<T, FileError>>`, for code on a UI thread.
