package std.fs;

import std.bytes.Bytes;
import std.fs.FileNatives;
import std.fs.FileNatives.RootHandle;
import std.fs.FileNatives.WriteMode;
import std.fs.Operations;

/**
 * A directory that nothing reached through it can leave: the operations of `Files`, with paths relative to it. `..`
 * fails, as does an absolute path, with `EscapesRoot`; a symbolic link is followed only while it stays beneath the
 * directory, and one that leads out fails the same way. It is for code that serves files to someone it does not trust,
 * such as a workspace server, a plugin host or a sandboxed app.
 *
 * The kernel resolves each path: openat2 with RESOLVE_BENEATH on Linux 5.6 or later, O_RESOLVE_BENEATH on macOS. On
 * Windows a path is opened and kept only when it resolved beneath the directory, and what an operation creates, deletes
 * or renames is named relative to a directory checked that way. Where none of these exists, `open` fails with
 * `Unsupported` rather than resolving paths in a way that could leave the directory. On Wasm a root is a directory of the
 * in-memory filesystem.
 *
 * A root holds the directory open until `close`, which a `scoped` binding calls at the end of its scope. Using a
 * closed root throws.
 */
class Root implements Disposable {
	/** The directory as it was given to `open`. */
	public final path:Path;

	var handle:Null<RootHandle>;

	function new(path:Path, handle:RootHandle) {
		this.path = path;
		this.handle = handle;
	}

	/** Opens the directory `path`, resolved as `Files` resolves it, as a root. */
	public static function open(path:Path):Result<Root, FileError> {
		var handle = FileNatives.openRoot(path.toString());
		return handle == null ? Err(FileNatives.lastError()) : Ok(new Root(path, handle));
	}

	/** Whether `close` has been called. */
	public function isClosed():Bool
		return handle == null;

	/** Lets go of the directory; the root cannot be used afterwards. Closing it again does nothing. */
	public function close():Void {
		var held = handle;
		handle = null;
		if (held != null)
			FileNatives.closeRoot(held);
	}

	/** Closes the root, as `close` does. */
	public function dispose():Void
		close();

	/** The bytes of the file `path`. */
	public function read(path:Path):Result<Bytes, FileError>
		return Operations.read(live(), path);

	/** The text of the file `path`, read as UTF-8. */
	public function readText(path:Path):Result<String, FileError>
		return Operations.readText(live(), path);

	/** Writes `content` to the file `path`, creating it or replacing what it held. */
	public function write(path:Path, content:Bytes):Result<Void, FileError>
		return Operations.write(live(), path, content, Replace);

	/** Writes `text` as UTF-8 to the file `path`, creating it or replacing what it held. */
	public function writeText(path:Path, text:String):Result<Void, FileError>
		return Operations.write(live(), path, Bytes.ofString(text), Replace);

	/** Adds `content` to the end of the file `path`, creating it when it is missing. */
	public function append(path:Path, content:Bytes):Result<Void, FileError>
		return Operations.write(live(), path, content, Append);

	/** Adds `text` as UTF-8 to the end of the file `path`, creating it when it is missing. */
	public function appendText(path:Path, text:String):Result<Void, FileError>
		return Operations.write(live(), path, Bytes.ofString(text), Append);

	/** Creates the file `path` holding `content`; `AlreadyExists` when anything is there, which is left as it was. */
	public function create(path:Path, content:Bytes):Result<Void, FileError>
		return Operations.write(live(), path, content, Create);

	/** Replaces the file `path` with `content` in one step, as `Files.writeAtomic` does. */
	public function writeAtomic(path:Path, content:Bytes):Result<Void, FileError>
		return Operations.writeAtomic(live(), path, content);

	/** What is at `path` (`.` for the root itself), following a symbolic link that stays beneath the root. */
	public function metadata(path:Path):Result<Metadata, FileError>
		return Operations.metadata(live(), path, true);

	/** What is at `path`; a symbolic link is described itself (`SymbolicLink`), not what it points to. */
	public function linkMetadata(path:Path):Result<Metadata, FileError>
		return Operations.metadata(live(), path, false);

	/** The entries of the directory `path` (`.` for the root itself), in no particular order. */
	public function list(path:Path):Result<Array<Entry>, FileError>
		return Operations.list(live(), path);

	/** Makes sure the directory `path` exists, with its missing parents, as `Files.createDirectory` does. */
	public function createDirectory(path:Path):Result<Void, FileError>
		return Operations.createDirectory(live(), path);

	/** Makes sure nothing is at `path`, as `Files.remove` does; the root itself cannot be removed. */
	public function remove(path:Path):Result<Void, FileError>
		return Operations.remove(live(), path);

	/** Deletes the file, symbolic link or empty directory `path`; `NotFound` when nothing is there. */
	public function delete(path:Path):Result<Void, FileError>
		return Operations.delete(live(), path);

	/** Makes sure nothing is at `path`, a directory's entries included, as `Files.removeTree` does. */
	public function removeTree(path:Path):Result<Void, FileError>
		return Operations.removeTree(live(), path);

	/** Moves the file or directory `path` to `target`, both beneath the root, replacing a file there. */
	public function rename(path:Path, target:Path):Result<Void, FileError>
		return Operations.rename(live(), path, target);

	/** Copies the bytes of the file `path` to the file `target`. */
	public function copy(path:Path, target:Path):Result<Void, FileError>
		return Operations.copy(live(), path, target);

	/** Opens the file `path` beneath the root as `mode` says, to read and write it a part at a time. */
	public function openFile(path:Path, mode:OpenMode):Result<FileHandle, FileError>
		return FileHandle.openIn(live(), path, mode);

	function live():RootHandle {
		var held = handle;
		if (held == null)
			throw new haxe.Exception('std.fs.Root for "$path" is closed');
		return held;
	}
}
