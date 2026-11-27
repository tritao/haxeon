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

import std.fs.FileNatives;

/**
 * Files and directories by path, as Haxe's API has them: whether they exist, what a directory holds, their status, and
 * creating, deleting and moving them, throwing where an operation fails. It runs on `std.fs`, which answers the same
 * operations with a `Result` instead; on Wasm the files are the session's in-memory filesystem.
 */
class FileSystem {
	/** Whether a file or directory exists at `path`. */
	public static function exists(path:String):Bool
		return FileNatives.kind(null, path, true) >= 0;

	/** Whether `path` is a directory. */
	public static function isDirectory(path:String):Bool
		return FileNatives.kind(null, path, true) == 1;

	/** `path` as an absolute path with its symbolic links resolved: the path of what exists there. */
	public static function fullPath(path:String):String
		return FileNatives.absolute(path);

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
		var names = FileNatives.names(null, path);
		if (names == null)
			throw failed("read directory", path);
		return names;
	}

	/** Lists child names and whether each is a directory, following a symbolic link, using one native enumeration. */
	public static function readDirectoryEntries(path:String):Array<FileSystemEntry> {
		var entries = FileNatives.list(null, path);
		if (entries == null)
			throw failed("read directory", path);
		return [for (entry in entries)
			new FileSystemEntry(entry.name, switch entry.kind {
				case Directory: true;
				case SymbolicLink: FileNatives.kind(null, path + "/" + entry.name, true) == 1;
				case _: false;
			})];
	}

	/** The file's status, as in Haxe; throws when there is no file at `path`. */
	public static function stat(path:String):FileStat {
		var values = FileNatives.stat(path);
		if (values == null)
			throw failed("stat", path);
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
		var values = FileNatives.stat(path);
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
		for (part in parts) {
			// A drive ("C:") and a directory that exists, or that another process creates meanwhile, need nothing.
			if (StringTools.endsWith(part, ":") || FileNatives.kind(null, part, true) == 1
				|| FileNatives.createDirectory(null, part))
				continue;
			var error = FileNatives.lastError();
			if (FileNatives.kind(null, part, true) != 1)
				throw 'Could not create directory "$part": ${error.describe()}';
		}
	}

	/** Deletes the file `path`. Throws when it cannot. */
	public static function deleteFile(path:String):Void
		if (!FileNatives.deleteFile(null, path)) throw failed("delete file", path);

	/** Removes the empty directory `path`. Throws when it cannot. */
	public static function deleteDirectory(path:String):Void
		if (!FileNatives.deleteDirectory(null, path)) throw failed("delete directory", path);

	/** Moves the file or directory `path` to `newPath`, replacing a file there. Throws when it cannot. */
	public static function rename(path:String, newPath:String):Void
		if (!FileNatives.rename(null, path, newPath)) throw failed('rename "$path" to', newPath);

	/** What a failed operation throws: `Could not delete file "a.txt": not found`. */
	static function failed(operation:String, path:String):String
		return 'Could not $operation "$path": ${FileNatives.lastError().describe()}';
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
