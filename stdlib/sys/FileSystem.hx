/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

package sys;

#if !wasm
@:hlNative("haxeon_runtime", "__sys_exists")
internal extern function fileSystemExists(path:String):Bool;

@:hlNative("haxeon_runtime", "__sys_is_dir")
internal extern function fileSystemIsDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__sys_full_path")
internal extern function fileSystemFullPath(path:String):String;

@:hlNative("haxeon_runtime", "__sys_read_dir")
internal extern function fileSystemReadDirectory(path:String):Array<String>;

@:hlNative("haxeon_runtime", "__sys_read_dir_entries")
internal extern function fileSystemReadDirectoryEntriesRaw(path:String):Array<String>;

@:hlNative("haxeon_runtime", "__sys_metadata")
internal extern function fileSystemMetadata(path:String):Null<Array<Int>>;

@:hlNative("haxeon_runtime", "__sys_create_dir")
internal extern function fileSystemCreateDirectory(path:String, mode:Int):Bool;

@:hlNative("haxeon_runtime", "__sys_delete")
internal extern function fileSystemDeleteFile(path:String):Bool;

@:hlNative("haxeon_runtime", "__sys_remove_dir")
internal extern function fileSystemDeleteDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__sys_rename")
internal extern function fileSystemRename(path:String, newPath:String):Bool;
#else
// Wasm keeps files in the session's in-memory filesystem (runtime.MemoryFileSystem).
function fileSystemExists(path:String):Bool
	return runtime.MemoryFileSystem.exists(path);

function fileSystemIsDirectory(path:String):Bool
	return runtime.MemoryFileSystem.isDirectory(path);

function fileSystemFullPath(path:String):String
	return runtime.MemoryFileSystem.normalize(path);

function fileSystemReadDirectory(path:String):Array<String>
	return runtime.MemoryFileSystem.readDirectory(path);

function fileSystemReadDirectoryEntriesRaw(path:String):Array<String> {
	var names = runtime.MemoryFileSystem.readDirectory(path);
	var entries:Array<String> = [];
	for (name in names) {
		entries.push(name);
		entries.push(runtime.MemoryFileSystem.isDirectory(runtime.MemoryFileSystem.normalize(path + "/" + name))
			? "d" : "f");
	}
	return entries;
}

function fileSystemMetadata(path:String):Null<Array<Int>>
	return runtime.MemoryFileSystem.stat(path);

/** Creates missing parents too, as the Haxe API documents. The mode is ignored. */
function fileSystemCreateDirectory(path:String, mode:Int):Bool
	return runtime.MemoryFileSystem.createDirectory(path, true);

function fileSystemDeleteFile(path:String):Bool
	return runtime.MemoryFileSystem.deleteFile(path);

function fileSystemDeleteDirectory(path:String):Bool
	return runtime.MemoryFileSystem.deleteDirectory(path);

function fileSystemRename(path:String, newPath:String):Bool
	return runtime.MemoryFileSystem.rename(path, newPath);
#end

/**
 * Files and directories by path: whether they exist, what a directory holds, their status, and creating, deleting and
 * moving them. On Wasm they are the session's in-memory filesystem.
 */
class FileSystem {
	/** Whether a file or directory exists at `path`. */
	public static function exists(path:String):Bool {
		var result = fileSystemExists(path);
		if (haxeon.build.InputFiles.isRecording())
			haxeon.build.InputFiles.existsQuery(path, result);
		return result;
	}

	/** Whether `path` is a directory. */
	public static function isDirectory(path:String):Bool {
		var result = fileSystemIsDirectory(path);
		if (haxeon.build.InputFiles.isRecording())
			haxeon.build.InputFiles.directoryQuery(path, result);
		return result;
	}

	/** `path` as an absolute path with its symbolic links resolved: the path of what exists there. */
	public static inline function fullPath(path:String):String
		return fileSystemFullPath(path);

	/** As Haxe's: a relative path joined onto the working directory, whether it exists or not; an absolute one as it is. */
	public static function absolutePath(relPath:String):String {
		if (haxe.io.Path.isAbsolute(relPath))
			return relPath;
		return haxe.io.Path.join([Sys.getCwd(), relPath]);
	}

	/**
	 * The names of the entries of the directory `path`, without `.` and `..`, in no particular order. Throws when it
	 * cannot be read.
	 */
	public static function readDirectory(path:String):Array<String> {
		if (!haxeon.build.InputFiles.isRecording())
			return fileSystemReadDirectory(path);
		var names:Null<Array<String>> = null;
		try
			names = fileSystemReadDirectory(path)
		catch (error:Dynamic) {
			haxeon.build.InputFiles.listingFailed(path);
			throw error;
		}
		haxeon.build.InputFiles.listingRead(path, names);
		return names;
	}

	/** Lists child names and their directory kinds using one native enumeration. */
	public static function readDirectoryEntries(path:String):Array<FileSystemEntry> {
		var raw = fileSystemReadDirectoryEntriesRaw(path);
		var entries:Array<FileSystemEntry> = [];
		var index = 0;
		while (index + 1 < raw.length) {
			entries.push(new FileSystemEntry(raw[index], raw[index + 1] == "d"));
			index += 2;
		}
		if (haxeon.build.InputFiles.isRecording())
			haxeon.build.InputFiles.listingRead(path, [for (entry in entries) entry.name]);
		return entries;
	}

	/** The file's status, as in Haxe; throws when there is no file at `path`. */
	public static function stat(path:String):FileStat {
		var values = fileSystemMetadata(path);
		if (values == null)
			throw 'Could not stat "$path"';
		return {
			gid: values[0],
			uid: values[1],
			atime: Date.fromTime(values[2] * 1000.0),
			mtime: Date.fromTime(values[3] * 1000.0),
			ctime: Date.fromTime(values[4] * 1000.0),
			size: values[5],
			dev: values[6],
			ino: values[7],
			nlink: values[8],
			rdev: values[9],
			mode: values[10]
		};
	}

	/** Lightweight metadata for change detection, or null when the path is unavailable. */
	public static function metadata(path:String):Null<FileMetadata> {
		var values = fileSystemMetadata(path);
		return values == null ? null : new FileMetadata(values[5], values[3], values[4]);
	}

	/** Creates `path` and any of its parents that do not exist, as Haxe does; throws when a directory cannot be created. */
	public static function createDirectory(path:String):Void {
		var current = haxe.io.Path.removeTrailingSlashes(path), parts = [];
		while (current != "") {
			parts.unshift(current);
			var parent = haxe.io.Path.directory(current);
			if (parent == current)
				break;
			current = parent;
		}
		for (part in parts)
			// A drive ("C:") and a directory that exists, or that another process creates meanwhile, need nothing.
			if (!StringTools.endsWith(part, ":") && !exists(part) && !fileSystemCreateDirectory(part, 493)
				&& !isDirectory(part))
				throw 'Failed to create directory $part';
	}

	/** Deletes the file `path`. Unlike Haxe's, it does not report a failure: check with `exists` when it matters. */
	public static inline function deleteFile(path:String):Void
		fileSystemDeleteFile(path);

	/**
	 * Removes the empty directory `path`. Unlike Haxe's, it does not report a failure: check with `exists` when it
	 * matters.
	 */
	public static inline function deleteDirectory(path:String):Void
		fileSystemDeleteDirectory(path);

	/** Moves the file or directory `path` to `newPath`, replacing a file there. Throws when it cannot. */
	public static inline function rename(path:String, newPath:String):Void
		if (!fileSystemRename(path, newPath)) throw 'Could not rename "$path" to "$newPath"';
}

/** What `FileSystem.metadata` reads: enough to tell whether a file changed. */
class FileMetadata {
	/** The size, in bytes. */
	public final size:Int;
	/** Last modification time in Unix seconds. */
	public final modified:Int;
	/** Last metadata change time in Unix seconds. */
	public final changed:Int;

	/** Metadata of a file of `size` bytes, modified and changed at those Unix seconds. */
	public function new(size:Int, modified:Int, changed:Int) {
		this.size = size;
		this.modified = modified;
		this.changed = changed;
	}
}

/** One entry of a directory, as `FileSystem.readDirectoryEntries` lists it. */
class FileSystemEntry {
	/** The entry's name, without the directory's path. */
	public final name:String;

	/** Whether the entry is a directory. */
	public final isDirectory:Bool;

	/** An entry named `name`. */
	public function new(name:String, isDirectory:Bool) {
		this.name = name;
		this.isDirectory = isDirectory;
	}
}
