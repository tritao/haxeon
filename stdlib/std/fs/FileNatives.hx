package std.fs;

import haxe.io.Bytes;
import std.fs.EntryKind;
import std.fs.FileError;
#if wasm
import runtime.MemoryFileSystem as Memory;
#end

// The runtime's file natives (native/runtime/fs.c) on native targets, and the session's in-memory filesystem
// (runtime.MemoryFileSystem) on Wasm, behind one contract: each answers its value, or null or false after recording
// why, which `lastError` reads back. Paths arrive normalized (`Path`).

/** How `write` opens a file: replacing what it holds, adding to its end, or only when nothing is there. */
internal enum abstract WriteMode(Int) to Int {
	var Replace = 0;
	var Append = 1;
	var Create = 2;
}

#if !wasm
@:hlNative("haxeon_runtime", "__fs_error")
internal extern function nativeError():Int;

@:hlNative("haxeon_runtime", "__fs_error_code")
internal extern function nativeErrorCode():Int;

@:hlNative("haxeon_runtime", "__fs_error_message")
internal extern function nativeErrorMessage():String;

@:hlNative("haxeon_runtime", "__fs_read")
internal extern function read(path:String):Null<Bytes>;

@:hlNative("haxeon_runtime", "__fs_write")
internal extern function write(path:String, content:Bytes, mode:Int):Bool;

@:hlNative("haxeon_runtime", "__fs_write_atomic")
internal extern function writeAtomic(path:String, content:Bytes, replace:Bool):Bool;

@:hlNative("haxeon_runtime", "__fs_metadata")
internal extern function nativeMetadata(path:String, follow:Bool, out:Bytes):Bool;

@:hlNative("haxeon_runtime", "__fs_list")
internal extern function nativeList(path:String):Null<Array<String>>;

@:hlNative("haxeon_runtime", "__fs_create_directory")
internal extern function createDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_delete_file")
internal extern function deleteFile(path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_delete_directory")
internal extern function deleteDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_rename")
internal extern function rename(path:String, target:String):Bool;

/** Why the last native on this thread failed. */
internal function lastError():FileError
	return switch nativeError() {
		case 1: NotFound;
		case 2: AlreadyExists;
		case 3: NotEmpty;
		case 4: NotADirectory;
		case 5: IsADirectory;
		case 6: PermissionDenied;
		case 7: EscapesRoot;
		case 8: Unsupported;
		case _: Io(nativeErrorCode(), nativeErrorMessage());
	}

/** What is at `path`, or null. */
internal function metadata(path:String, follow:Bool):Null<Metadata> {
	var out = Bytes.alloc(24);
	if (!nativeMetadata(path, follow, out))
		return null;
	return new Metadata(kindOf(out.getInt32(0)), out.getInt64(8), out.getDouble(16));
}

/** The entries of the directory `path`, or null. */
internal function list(path:String):Null<Array<Entry>> {
	var raw = nativeList(path);
	if (raw == null)
		return null;
	var entries:Array<Entry> = [];
	var index = 0;
	while (index + 1 < raw.length) {
		entries.push(new Entry(raw[index], switch raw[index + 1] {
			case "f": File;
			case "d": Directory;
			case "l": SymbolicLink;
			case _: Other;
		}));
		index += 2;
	}
	return entries;
}

internal function kindOf(code:Int):EntryKind
	return switch code {
		case 0: File;
		case 1: Directory;
		case 2: SymbolicLink;
		case _: Other;
	};
#else
internal var failure:FileError = NotFound;

internal function lastError():FileError
	return failure;

internal function fail<T>(error:FileError, answer:T):T {
	failure = error;
	return answer;
}

/** Why `path`'s parent cannot hold a new entry, or null when it can. */
internal function parentProblem(path:String):Null<FileError> {
	var full = Memory.normalize(path);
	var slash = full.lastIndexOf("/");
	var parent = slash <= 0 ? "/" : full.substr(0, slash);
	if (Memory.isDirectory(parent))
		return null;
	return Memory.exists(parent) ? NotADirectory : NotFound;
}

internal function read(path:String):Null<Bytes> {
	if (!Memory.exists(path))
		return fail(NotFound, null);
	if (Memory.isDirectory(path))
		return fail(IsADirectory, null);
	return Memory.getBytes(path);
}

internal function write(path:String, content:Bytes, mode:Int):Bool {
	if (Memory.isDirectory(path))
		return fail(IsADirectory, false);
	var problem = parentProblem(path);
	if (problem != null)
		return fail(problem, false);
	var existing = Memory.exists(path);
	if (mode == Create && existing)
		return fail(AlreadyExists, false);
	if (mode == Append && existing) {
		var before = Memory.getBytes(path);
		var combined = Bytes.alloc(before.length + content.length);
		combined.blit(0, before, 0, before.length);
		combined.blit(before.length, content, 0, content.length);
		content = combined;
	}
	Memory.saveBytes(path, content);
	return true;
}

internal function writeAtomic(path:String, content:Bytes, replace:Bool):Bool {
	if (Memory.isDirectory(path))
		return fail(IsADirectory, false);
	if (!replace && Memory.exists(path))
		return fail(AlreadyExists, false);
	return write(path, content, Replace);
}

internal function metadata(path:String, follow:Bool):Null<Metadata> {
	var values = Memory.stat(path);
	if (values == null)
		return fail(NotFound, null);
	var directory = Memory.isDirectory(path);
	return new Metadata(directory ? Directory : File, haxe.Int64.ofInt(values[5]), values[3]);
}

internal function list(path:String):Null<Array<Entry>> {
	if (!Memory.exists(path))
		return fail(NotFound, null);
	var names = Memory.readDirectory(path);
	if (names == null)
		return fail(NotADirectory, null);
	var full = Memory.normalize(path);
	return [
		for (name in names)
			new Entry(name, Memory.isDirectory(full == "/" ? "/" + name : full + "/" + name) ? Directory : File)
	];
}

internal function createDirectory(path:String):Bool {
	if (Memory.exists(path))
		return fail(AlreadyExists, false);
	var problem = parentProblem(path);
	if (problem != null)
		return fail(problem, false);
	return Memory.createDirectory(path);
}

internal function deleteFile(path:String):Bool {
	if (!Memory.exists(path))
		return fail(NotFound, false);
	if (Memory.isDirectory(path))
		return fail(IsADirectory, false);
	return Memory.deleteFile(path);
}

internal function deleteDirectory(path:String):Bool {
	if (!Memory.exists(path))
		return fail(NotFound, false);
	if (!Memory.isDirectory(path))
		return fail(NotADirectory, false);
	if (Memory.normalize(path) == "/")
		return fail(PermissionDenied, false);
	if (!Memory.deleteDirectory(path))
		return fail(NotEmpty, false);
	return true;
}

internal function rename(path:String, target:String):Bool {
	if (!Memory.exists(path))
		return fail(NotFound, false);
	var problem = parentProblem(target);
	if (problem != null)
		return fail(problem, false);
	var moving = Memory.isDirectory(path);
	if (Memory.exists(target)) {
		var replacing = Memory.isDirectory(target);
		if (moving && !replacing)
			return fail(NotADirectory, false);
		if (!moving && replacing)
			return fail(IsADirectory, false);
	}
	if (!Memory.rename(path, target))
		// What is left: a directory moved into itself, or over one that has entries.
		return fail(moving && Memory.exists(target) ? NotEmpty : Io(22, "Invalid argument"), false);
	return true;
}
#end
