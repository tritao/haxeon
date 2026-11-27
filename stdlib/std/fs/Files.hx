package std.fs;

import haxe.io.Bytes;
import std.fs.EntryKind;
import std.fs.FileNatives;
import std.fs.FileNatives.WriteMode;

/*
 * Files and directories by path, resolved as the operating system resolves them: absolute, or against the working
 * directory, following `..` and symbolic links. Each operation returns a `Result` whose `Err` says why it failed
 * (`FileError`); none throws. Called as `Files.read(path)` after `import std.fs.Files;`. On Wasm the files are the
 * session's in-memory filesystem.
 */

/** The bytes of the file `path`. */
function read(path:Path):Result<Bytes, FileError> {
	var bytes = FileNatives.read(path.toString());
	return bytes == null ? Err(FileNatives.lastError()) : Ok(bytes);
}

/** The text of the file `path`, read as UTF-8. */
function readText(path:Path):Result<String, FileError>
	return read(path).map(bytes -> bytes.toString());

/** Writes `content` to the file `path`, creating it or replacing what it held. */
function write(path:Path, content:Bytes):Result<Void, FileError>
	return written(FileNatives.write(path.toString(), content, Replace));

/** Writes `text` as UTF-8 to the file `path`, creating it or replacing what it held. */
function writeText(path:Path, text:String):Result<Void, FileError>
	return write(path, Bytes.ofString(text));

/** Adds `content` to the end of the file `path`, creating it when it is missing. */
function append(path:Path, content:Bytes):Result<Void, FileError>
	return written(FileNatives.write(path.toString(), content, Append));

/** Adds `text` as UTF-8 to the end of the file `path`, creating it when it is missing. */
function appendText(path:Path, text:String):Result<Void, FileError>
	return append(path, Bytes.ofString(text));

/** Creates the file `path` holding `content`; `AlreadyExists` when anything is there, which is left as it was. */
function create(path:Path, content:Bytes):Result<Void, FileError>
	return written(FileNatives.write(path.toString(), content, Create));

/**
 * Replaces the file `path` with `content` in one step: a reader, or a crash, sees the old file or the new one, never
 * part of either. The content goes to a temporary file beside `path`, reaches the disk, and is moved into place.
 */
function writeAtomic(path:Path, content:Bytes):Result<Void, FileError>
	return written(FileNatives.writeAtomic(path.toString(), content, true));

/** What is at `path`, following a symbolic link to what it points to. */
function metadata(path:Path):Result<Metadata, FileError>
	return described(path, true);

/** What is at `path`; a symbolic link is described itself (`SymbolicLink`), not what it points to. */
function linkMetadata(path:Path):Result<Metadata, FileError>
	return described(path, false);

/** The entries of the directory `path`, in no particular order, without `.` and `..`. */
function list(path:Path):Result<Array<Entry>, FileError> {
	var entries = FileNatives.list(path.toString());
	return entries == null ? Err(FileNatives.lastError()) : Ok(entries);
}

/**
 * Makes sure the directory `path` exists: creates it and any missing parents, and succeeds when it is already there.
 * `AlreadyExists` when something other than a directory is at `path`, `NotADirectory` when one is on the way to it.
 */
function createDirectory(path:Path):Result<Void, FileError> {
	if (FileNatives.createDirectory(path.toString()))
		return Ok();
	var error = FileNatives.lastError();
	switch error {
		case AlreadyExists:
			return isDirectory(path) ? Ok() : Err(AlreadyExists);
		case NotFound:
			var parent = path.parent();
			if (parent == null)
				return Err(error);
			try createDirectory(parent);
			// The parent exists now; another process may have made `path` meanwhile.
			if (FileNatives.createDirectory(path.toString()))
				return Ok();
			var retried = FileNatives.lastError();
			return isDirectory(path) ? Ok() : Err(retried);
		default:
			return Err(error);
	}
}

/**
 * Makes sure nothing is at `path`: deletes a file, a symbolic link (not what it points to) or an empty directory, and
 * succeeds when nothing was there. `NotEmpty` for a directory with entries; `removeTree` removes those too.
 */
function remove(path:Path):Result<Void, FileError>
	return switch delete(path) {
		case Err(NotFound): Ok();
		case other: other;
	}

/** Deletes the file, symbolic link or empty directory `path`, as `remove` does, but `NotFound` when nothing is there. */
function delete(path:Path):Result<Void, FileError> {
	var text = path.toString();
	var described = FileNatives.metadata(text, false);
	if (described == null)
		return Err(FileNatives.lastError());
	var deleted = described.kind == Directory ? FileNatives.deleteDirectory(text) : FileNatives.deleteFile(text);
	return written(deleted);
}

/**
 * Makes sure nothing is at `path`, a directory's entries included: removes the tree beneath it first, depth first, and
 * succeeds when nothing was there. A symbolic link is removed itself; what it points to is left alone.
 */
function removeTree(path:Path):Result<Void, FileError> {
	var described = FileNatives.metadata(path.toString(), false);
	if (described == null)
		return switch FileNatives.lastError() {
			case NotFound: Ok();
			case error: Err(error);
		}
	if (described.kind == Directory) {
		var entries = switch FileNatives.list(path.toString()) {
			case null: return Err(FileNatives.lastError());
			case found: found;
		}
		for (entry in entries) {
			var child = path.join(entry.name);
			if (entry.kind == Directory) {
				try removeTree(child);
			} else {
				try remove(child);
			}
		}
	}
	return remove(path);
}

/** Moves the file or directory `path` to `target`, replacing a file there; both must be on the same volume. */
function rename(path:Path, target:Path):Result<Void, FileError> {
	return written(FileNatives.rename(path.toString(), target.toString()));
}

/** Copies the bytes of the file `path` to the file `target`, creating it or replacing what it held. */
function copy(path:Path, target:Path):Result<Void, FileError> {
	var bytes = try read(path);
	return write(target, bytes);
}

internal function isDirectory(path:Path):Bool {
	var described = FileNatives.metadata(path.toString(), true);
	return described != null && described.kind == Directory;
}

internal function described(path:Path, follow:Bool):Result<Metadata, FileError> {
	var found = FileNatives.metadata(path.toString(), follow);
	return found == null ? Err(FileNatives.lastError()) : Ok(found);
}

/** The result of a change that `succeeded`, or why it did not. */
internal function written(succeeded:Bool):Result<Void, FileError>
	return succeeded ? Ok() : Err(FileNatives.lastError());
