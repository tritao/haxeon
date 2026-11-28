package std.fs;

import std.bytes.Bytes;
import std.fs.EntryKind;
import std.fs.FileNatives;
import std.fs.FileNatives.RootHandle;
import std.fs.FileNatives.WriteMode;

// What `Files` and `Root` do, written once: each takes the root it resolves paths beneath, null for the process's own
// view, and turns the natives' answer into a Result.

internal function read(root:Null<RootHandle>, path:Path):Result<Bytes, FileError> {
	var bytes = FileNatives.read(root, path.toString());
	return bytes == null ? Err(FileNatives.lastError()) : Ok(bytes);
}

internal function readText(root:Null<RootHandle>, path:Path):Result<String, FileError> {
	var text = FileNatives.readText(root, path.toString());
	return text == null ? Err(FileNatives.lastError()) : Ok(text);
}

internal function write(root:Null<RootHandle>, path:Path, content:Bytes, mode:WriteMode):Result<Void, FileError>
	return done(FileNatives.write(root, path.toString(), content, mode));

internal function writeAtomic(root:Null<RootHandle>, path:Path, content:Bytes):Result<Void, FileError>
	return done(FileNatives.writeAtomic(root, path.toString(), content, true));

internal function metadata(root:Null<RootHandle>, path:Path, follow:Bool):Result<Metadata, FileError> {
	var found = FileNatives.metadata(root, path.toString(), follow);
	return found == null ? Err(FileNatives.lastError()) : Ok(found);
}

internal function list(root:Null<RootHandle>, path:Path):Result<Array<Entry>, FileError> {
	var entries = FileNatives.list(root, path.toString());
	return entries == null ? Err(FileNatives.lastError()) : Ok(entries);
}

internal function createDirectory(root:Null<RootHandle>, path:Path):Result<Void, FileError> {
	if (FileNatives.createDirectory(root, path.toString()))
		return Ok();
	var error = FileNatives.lastError();
	switch error {
		case AlreadyExists:
			return isDirectory(root, path) ? Ok() : Err(AlreadyExists);
		case NotFound:
			var parent = path.parent();
			if (parent == null)
				return Err(error);
			try createDirectory(root, parent);
			// The parent exists now; another process may have made `path` meanwhile.
			if (FileNatives.createDirectory(root, path.toString()))
				return Ok();
			var retried = FileNatives.lastError();
			return isDirectory(root, path) ? Ok() : Err(retried);
		default:
			return Err(error);
	}
}

internal function remove(root:Null<RootHandle>, path:Path):Result<Void, FileError>
	return switch delete(root, path) {
		case Err(NotFound): Ok();
		case other: other;
	}

internal function delete(root:Null<RootHandle>, path:Path):Result<Void, FileError> {
	var text = path.toString();
	var described = FileNatives.metadata(root, text, false);
	if (described == null)
		return Err(FileNatives.lastError());
	return done(described.kind == Directory ? FileNatives.deleteDirectory(root, text) : FileNatives.deleteFile(root,
		text));
}

internal function removeTree(root:Null<RootHandle>, path:Path):Result<Void, FileError> {
	// A root cannot remove itself, so it does not remove what it holds on the way either.
	if (root != null && path.toString() == ".")
		return Err(PermissionDenied);
	var described = FileNatives.metadata(root, path.toString(), false);
	if (described == null)
		return switch FileNatives.lastError() {
			case NotFound: Ok();
			case error: Err(error);
		}
	if (described.kind == Directory) {
		var entries = switch FileNatives.list(root, path.toString()) {
			case null: return Err(FileNatives.lastError());
			case found: found;
		}
		for (entry in entries) {
			var child = path.join(entry.name);
			if (entry.kind == Directory) {
				try removeTree(root, child);
			} else {
				try remove(root, child);
			}
		}
	}
	return remove(root, path);
}

internal function rename(root:Null<RootHandle>, path:Path, target:Path):Result<Void, FileError>
	return done(FileNatives.rename(root, path.toString(), target.toString()));

internal function copy(root:Null<RootHandle>, path:Path, target:Path):Result<Void, FileError> {
	var bytes = try read(root, path);
	return write(root, target, bytes, Replace);
}

internal function isDirectory(root:Null<RootHandle>, path:Path):Bool {
	var described = FileNatives.metadata(root, path.toString(), true);
	return described != null && described.kind == Directory;
}

/** The result of a change that `succeeded`, or why it did not. */
internal function done(succeeded:Bool):Result<Void, FileError>
	return succeeded ? Ok() : Err(FileNatives.lastError());
