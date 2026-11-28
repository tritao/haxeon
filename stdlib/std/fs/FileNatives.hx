package std.fs;

import std.bytes.Bytes;
import std.fs.EntryKind;
import std.fs.FileError;
#if wasm
import runtime.MemoryFileSystem as Memory;
#end

// The runtime's file natives (native/runtime/fs.c) on native targets, and the session's in-memory filesystem
// (runtime.MemoryFileSystem) on Wasm, behind one contract: each takes a root (null for the process's own view) and
// answers its value, or null or false after recording why, which `lastError` reads back. Paths arrive normalized
// (`Path`); beneath a root they are relative to it, and one that would leave it fails with EscapesRoot.

/** How `write` opens a file: replacing what it holds, adding to its end, or only when nothing is there. */
internal enum abstract WriteMode(Int) to Int {
	var Replace = 0;
	var Append = 1;
	var Create = 2;
}

#if !wasm
/** A directory the runtime resolves paths beneath, or null for the process's own view. */
internal typedef RootHandle = hl.Abstract<"realtime_fs_root">;

@:hlNative("haxeon_runtime", "__fs_error")
internal extern function nativeError():Int;

@:hlNative("haxeon_runtime", "__fs_error_code")
internal extern function nativeErrorCode():Int;

@:hlNative("haxeon_runtime", "__fs_error_message")
internal extern function nativeErrorMessage():String;

@:hlNative("haxeon_runtime", "__fs_root_open")
internal extern function openRoot(path:String):Null<RootHandle>;

@:hlNative("haxeon_runtime", "__fs_root_close")
internal extern function closeRoot(root:RootHandle):Void;

@:hlNative("haxeon_runtime", "__fs_read")
internal extern function read(root:Null<RootHandle>, path:String):Null<Bytes>;

@:hlNative("haxeon_runtime", "__fs_write")
internal extern function write(root:Null<RootHandle>, path:String, content:Bytes, mode:Int):Bool;

@:hlNative("haxeon_runtime", "__fs_write_atomic")
internal extern function writeAtomic(root:Null<RootHandle>, path:String, content:Bytes, replace:Bool):Bool;

@:hlNative("haxeon_runtime", "__fs_read_text")
internal extern function readText(root:Null<RootHandle>, path:String):Null<String>;

/** What kind of entry is at `path` (an EntryKind's index), or -1. */
@:hlNative("haxeon_runtime", "__fs_kind")
internal extern function kind(root:Null<RootHandle>, path:String, follow:Bool):Int;

/** `path` as an absolute path: its links resolved on POSIX, resolved against the working directory on Windows. */
@:hlNative("haxeon_runtime", "__fs_absolute")
internal extern function absolute(path:String):Null<String>;

/** Haxe's FileStat fields of `path` in its order (gid, uid, atime, mtime, ctime, size, dev, ino, nlink, rdev, mode), or null. */
@:hlNative("haxeon_runtime", "__fs_stat")
internal extern function stat(path:String):Null<Array<Int>>;

@:hlNative("haxeon_runtime", "__fs_metadata")
internal extern function nativeMetadata(root:Null<RootHandle>, path:String, follow:Bool, out:Bytes):Bool;

@:hlNative("haxeon_runtime", "__fs_list")
internal extern function nativeList(root:Null<RootHandle>, path:String):Null<Array<String>>;

@:hlNative("haxeon_runtime", "__fs_create_directory")
internal extern function createDirectory(root:Null<RootHandle>, path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_delete_file")
internal extern function deleteFile(root:Null<RootHandle>, path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_delete_directory")
internal extern function deleteDirectory(root:Null<RootHandle>, path:String):Bool;

@:hlNative("haxeon_runtime", "__fs_rename")
internal extern function rename(root:Null<RootHandle>, path:String, target:String):Bool;

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
internal function metadata(root:Null<RootHandle>, path:String, follow:Bool):Null<Metadata> {
	var out = Bytes.alloc(24);
	if (!nativeMetadata(root, path, follow, out))
		return null;
	return new Metadata(kindOf(out.getInt32(0)), out.getInt64(8), out.getDouble(16));
}

/** The names in the directory `path`, or null. */
internal function names(root:Null<RootHandle>, path:String):Null<Array<String>> {
	var raw = nativeList(root, path);
	if (raw == null)
		return null;
	return [for (index in 0...(raw.length >> 1)) raw[index * 2]];
}

/** The entries of the directory `path`, or null. */
internal function list(root:Null<RootHandle>, path:String):Null<Array<Entry>> {
	var raw = nativeList(root, path);
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
/** On Wasm, a root is the absolute path of its directory in the in-memory filesystem, which has no symbolic links. */
internal typedef RootHandle = String;

internal var failure:FileError = NotFound;

internal function lastError():FileError
	return failure;

internal function fail<T>(error:FileError, answer:T):T {
	failure = error;
	return answer;
}

/** `path` in the in-memory filesystem, beneath `root` when there is one, or null after recording why. */
internal function resolve(root:Null<RootHandle>, path:String):Null<String> {
	if (root == null)
		return path;
	if (StringTools.startsWith(path, "/") || path.split("/").indexOf("..") >= 0)
		return fail(EscapesRoot, null);
	return path == "." ? root : root == "/" ? "/" + path : root + "/" + path;
}

internal function openRoot(path:String):Null<RootHandle> {
	if (!Memory.exists(path))
		return fail(NotFound, null);
	if (!Memory.isDirectory(path))
		return fail(NotADirectory, null);
	return Memory.normalize(path);
}

internal function closeRoot(root:RootHandle):Void {}

/** Why `path`'s parent cannot hold a new entry, or null when it can. */
internal function parentProblem(path:String):Null<FileError> {
	var full = Memory.normalize(path);
	var slash = full.lastIndexOf("/");
	var parent = slash <= 0 ? "/" : full.substr(0, slash);
	if (Memory.isDirectory(parent))
		return null;
	return Memory.exists(parent) ? NotADirectory : NotFound;
}

internal function read(root:Null<RootHandle>, path:String):Null<Bytes> {
	var full = resolve(root, path);
	if (full == null)
		return null;
	if (!Memory.exists(full))
		return fail(NotFound, null);
	if (Memory.isDirectory(full))
		return fail(IsADirectory, null);
	return Memory.getBytes(full);
}

internal function write(root:Null<RootHandle>, path:String, content:Bytes, mode:Int):Bool {
	var full = resolve(root, path);
	if (full == null)
		return false;
	if (Memory.isDirectory(full))
		return fail(IsADirectory, false);
	var problem = parentProblem(full);
	if (problem != null)
		return fail(problem, false);
	var existing = Memory.exists(full);
	if (mode == Create && existing)
		return fail(AlreadyExists, false);
	if (mode == Append && existing) {
		var before = Memory.getBytes(full);
		var combined = Bytes.alloc(before.length + content.length);
		combined.blit(0, before, 0, before.length);
		combined.blit(before.length, content, 0, content.length);
		content = combined;
	}
	Memory.saveBytes(full, content);
	return true;
}

internal function writeAtomic(root:Null<RootHandle>, path:String, content:Bytes, replace:Bool):Bool
	return write(root, path, content, replace ? Replace : Create);

internal function readText(root:Null<RootHandle>, path:String):Null<String> {
	var bytes = read(root, path);
	if (bytes == null)
		return null;
	for (index in 0...bytes.length)
		if (bytes.get(index) == 0)
			return fail(Io(-1, "the file holds a NUL character, which a String cannot"), null);
	return bytes.toString();
}

internal function kind(root:Null<RootHandle>, path:String, follow:Bool):Int {
	var full = resolve(root, path);
	if (full == null)
		return -1;
	if (!Memory.exists(full))
		return fail(NotFound, -1);
	return Memory.isDirectory(full) ? 1 : 0;
}

internal function absolute(path:String):Null<String>
	return Memory.normalize(path);

internal function workingDirectory():String
	return Memory.getCwd();

internal function setWorkingDirectory(path:String):Bool {
	var full = Memory.normalize(path);
	if (!Memory.exists(full))
		return fail(NotFound, false);
	if (!Memory.isDirectory(full))
		return fail(NotADirectory, false);
	return Memory.setCwd(full) ? true : fail(PermissionDenied, false);
}

internal function canonical(path:String):Null<String> {
	var full = Memory.normalize(path);
	return Memory.exists(full) ? full : fail(NotFound, null);
}

internal function stat(path:String):Null<Array<Int>> {
	var values = Memory.stat(path);
	return values == null ? fail(NotFound, null) : values;
}

internal function names(root:Null<RootHandle>, path:String):Null<Array<String>> {
	var entries = list(root, path);
	return entries == null ? null : [for (entry in entries) entry.name];
}

internal function metadata(root:Null<RootHandle>, path:String, follow:Bool):Null<Metadata> {
	var full = resolve(root, path);
	if (full == null)
		return null;
	var values = Memory.stat(full);
	if (values == null)
		return fail(NotFound, null);
	return new Metadata(Memory.isDirectory(full) ? Directory : File, haxe.Int64.ofInt(values[5]), values[3]);
}

internal function list(root:Null<RootHandle>, path:String):Null<Array<Entry>> {
	var full = resolve(root, path);
	if (full == null)
		return null;
	if (!Memory.exists(full))
		return fail(NotFound, null);
	var names = Memory.readDirectory(full);
	if (names == null)
		return fail(NotADirectory, null);
	var directory = Memory.normalize(full);
	return [
		for (name in names)
			new Entry(name,
			Memory.isDirectory(directory == "/" ? "/" + name : directory + "/" + name) ? Directory : File)
	];
}

internal function createDirectory(root:Null<RootHandle>, path:String):Bool {
	var full = resolve(root, path);
	if (full == null)
		return false;
	if (Memory.exists(full))
		return fail(AlreadyExists, false);
	var problem = parentProblem(full);
	if (problem != null)
		return fail(problem, false);
	return Memory.createDirectory(full);
}

internal function deleteFile(root:Null<RootHandle>, path:String):Bool {
	var full = resolve(root, path);
	if (full == null)
		return false;
	if (!Memory.exists(full))
		return fail(NotFound, false);
	if (Memory.isDirectory(full))
		return fail(IsADirectory, false);
	return Memory.deleteFile(full);
}

internal function deleteDirectory(root:Null<RootHandle>, path:String):Bool {
	var full = resolve(root, path);
	if (full == null)
		return false;
	if (!Memory.exists(full))
		return fail(NotFound, false);
	if (!Memory.isDirectory(full))
		return fail(NotADirectory, false);
	if (Memory.normalize(full) == "/" || root != null && path == ".")
		return fail(PermissionDenied, false);
	if (!Memory.deleteDirectory(full))
		return fail(NotEmpty, false);
	return true;
}

internal function rename(root:Null<RootHandle>, path:String, target:String):Bool {
	var from = resolve(root, path), to = resolve(root, target);
	if (from == null || to == null)
		return false;
	if (root != null && (path == "." || target == "."))
		return fail(PermissionDenied, false);
	if (!Memory.exists(from))
		return fail(NotFound, false);
	var problem = parentProblem(to);
	if (problem != null)
		return fail(problem, false);
	var moving = Memory.isDirectory(from);
	if (Memory.exists(to)) {
		var replacing = Memory.isDirectory(to);
		if (moving && !replacing)
			return fail(NotADirectory, false);
		if (!moving && replacing)
			return fail(IsADirectory, false);
	}
	if (!Memory.rename(from, to))
		// What is left: a directory moved into itself, or over one that has entries.
		return fail(moving && Memory.exists(to) ? NotEmpty : Io(22, "Invalid argument"), false);
	return true;
}
#end
