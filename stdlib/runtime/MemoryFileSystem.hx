package runtime;

#if wasm
import haxe.io.Bytes;

/**
 * The Wasm filesystem behind `sys.io.File`, `sys.io.AtomicFile`, `sys.FileSystem` and the `Sys`
 * path operations. Files live in module memory and vanish with the instance, unless a host
 * keeps them: it can fill the store before the program uses it and set `observer` to mirror
 * every later change to storage of its own.
 *
 * Paths are absolute from "/" or relative to the working directory; repeated separators, "."
 * and ".." are normalized away. Operations report failure as the HashLink runtime does: the
 * boolean ones return false, whole-file reads and writes throw its error messages, and atomic
 * writes return an error string. Modification times are a per-session write counter rather than
 * wall-clock seconds; they only ever increase, which is what change detection needs.
 */
class MemoryFileSystem {
	/** Every file and directory by normalized path; the root always exists. */
	static final entries:Map<String, MemoryEntry> = ["/" => new MemoryEntry(null, 0)];
	static var clock = 0;
	static var workingDirectory = "/";

	/** Told about each change after it happens, in order; null when nothing mirrors the store. */
	public static var observer:Null<MemoryFileSystemObserver> = null;

	/** The absolute, normalized form of `path`. */
	public static function normalize(path:String):String {
		var source = path == null ? "" : path;
		if (!StringTools.startsWith(source, "/"))
			source = workingDirectory + "/" + source;
		var parts:Array<String> = [];
		for (part in source.split("/"))
			if (part == "..") {
				if (parts.length > 0)
					parts.pop();
			} else if (part != "" && part != ".")
				parts.push(part);
		return "/" + parts.join("/");
	}

	/** The working directory with a trailing separator, as HashLink reports it. */
	public static function getCwd():String
		return workingDirectory == "/" ? "/" : workingDirectory + "/";

	public static function setCwd(path:String):Bool {
		var target = normalize(path);
		if (!isDirectoryAt(target))
			return false;
		workingDirectory = target;
		return true;
	}

	public static function exists(path:String):Bool
		return entries.exists(normalize(path));

	public static function isDirectory(path:String):Bool
		return isDirectoryAt(normalize(path));

	/** Entry names directly inside a directory, sorted, or null when it is not a directory. */
	public static function readDirectory(path:String):Null<Array<String>> {
		var target = normalize(path);
		if (!isDirectoryAt(target))
			return null;
		var names:Array<String> = [];
		for (entry in entries.keys())
			if (entry != "/" && parentOf(entry) == target)
				names.push(entry.substr(entry.lastIndexOf("/") + 1));
		names.sort(Reflect.compare);
		return names;
	}

	/** Creates a directory; `recursive` also creates missing parents, as `mkdir -p` does. */
	public static function createDirectory(path:String, recursive:Bool):Bool {
		var target = normalize(path);
		if (entries.exists(target))
			return false;
		var parent = parentOf(target);
		if (!isDirectoryAt(parent) && (!recursive || !createDirectory(parent, true)))
			return false;
		entries.set(target, new MemoryEntry(null, ++clock));
		if (observer != null)
			observer.directoryCreated(target);
		return true;
	}

	/** Removes an empty directory. */
	public static function deleteDirectory(path:String):Bool {
		var target = normalize(path);
		if (target == "/" || !isDirectoryAt(target) || hasChildren(target))
			return false;
		entries.remove(target);
		if (observer != null)
			observer.removed(target);
		return true;
	}

	public static function deleteFile(path:String):Bool {
		var target = normalize(path);
		if (fileAt(target) == null)
			return false;
		entries.remove(target);
		if (observer != null)
			observer.removed(target);
		return true;
	}

	/**
	 * Moves a file or directory tree as POSIX `rename` does: a file may replace a file, and a
	 * directory may replace an empty directory.
	 */
	public static function rename(path:String, newPath:String):Bool {
		var source = normalize(path), target = normalize(newPath);
		var moving = entries.get(source), replaced = entries.get(target);
		if (source == "/" || moving == null || !isDirectoryAt(parentOf(target)))
			return false;
		if (source == target)
			return true;
		if (replaced != null) {
			var directory = moving.content == null;
			if (directory != (replaced.content == null) || directory && hasChildren(target))
				return false;
		}
		if (StringTools.startsWith(target, source + "/"))
			return false;
		var prefix = source + "/";
		var inside = [for (entry in entries.keys()) if (StringTools.startsWith(entry, prefix)) entry];
		for (entry in inside) {
			entries.set(target + entry.substr(source.length), entries.get(entry));
			entries.remove(entry);
		}
		entries.remove(source);
		entries.set(target, moving);
		if (observer != null)
			observer.renamed(source, target);
		return true;
	}

	/**
	 * `stat` fields in HashLink's order: gid, uid, atime, mtime, ctime, size, dev, ino, nlink,
	 * rdev, mode. Null when nothing exists at the path.
	 */
	public static function stat(path:String):Null<Array<Int>> {
		var entry = entries.get(normalize(path));
		if (entry == null)
			return null;
		var time = entry.modified;
		var size = entry.content == null ? 0 : entry.content.length;
		var mode = entry.content == null ? 0x41ED : 0x81A4;
		return [0, 0, time, time, time, size, 0, 0, 1, 0, mode];
	}

	public static function getBytes(path:String):Bytes {
		var content = fileAt(normalize(path));
		if (content == null)
			throw "Could not open source file";
		return content.sub(0, content.length);
	}

	public static function getContent(path:String):String {
		var content = getBytes(path);
		for (index in 0...content.length)
			if (content.get(index) == 0)
				throw "HashLink String cannot contain NUL; use File.getBytes for binary data";
		return content.toString();
	}

	public static function saveBytes(path:String, content:Bytes):Void {
		if (!store(normalize(path), content.sub(0, content.length)))
			throw "Could not open output file";
	}

	public static function saveContent(path:String, content:String):Void {
		if (!store(normalize(path), Bytes.ofString(content == null ? "" : content)))
			throw "Could not open output file";
	}

	public static function appendContent(path:String, content:String):Void {
		var target = normalize(path);
		var existing = fileAt(target), combined = Bytes.ofString(content == null ? "" : content);
		if (existing != null) {
			var addition = combined;
			combined = Bytes.alloc(existing.length + addition.length);
			combined.blit(0, existing, 0, existing.length);
			combined.blit(existing.length, addition, 0, addition.length);
		}
		if (!store(target, combined))
			throw "Could not open append file";
	}

	/**
	 * Publishes `content` in one step, returning null or the error text the POSIX runtime
	 * reports. Without `replace`, an existing destination is left untouched.
	 */
	public static function writeAtomic(path:String, content:Bytes, replace:Bool):Null<String> {
		if (content == null)
			return "content is null";
		var target = normalize(path);
		if (isDirectoryAt(target))
			return "Is a directory";
		if (!isDirectoryAt(parentOf(target)))
			return "No such file or directory";
		if (!replace && entries.exists(target))
			return "File exists";
		store(target, content.sub(0, content.length));
		return null;
	}

	static function store(target:String, content:Bytes):Bool {
		if (isDirectoryAt(target) || !isDirectoryAt(parentOf(target)))
			return false;
		entries.set(target, new MemoryEntry(content, ++clock));
		if (observer != null)
			observer.fileWritten(target, content);
		return true;
	}

	static function isDirectoryAt(target:String):Bool {
		var entry = entries.get(target);
		return entry != null && entry.content == null;
	}

	static function fileAt(target:String):Null<Bytes> {
		var entry = entries.get(target);
		return entry == null ? null : entry.content;
	}

	static function hasChildren(directory:String):Bool {
		for (entry in entries.keys())
			if (entry != "/" && parentOf(entry) == directory)
				return true;
		return false;
	}

	static function parentOf(target:String):String {
		var separator = target.lastIndexOf("/");
		return separator <= 0 ? "/" : target.substr(0, separator);
	}
}

/**
 * Receives MemoryFileSystem changes with normalized absolute paths. A rename moves a whole tree, and a
 * directory is created only after its parent; `content` belongs to the store and must not be changed.
 */
interface MemoryFileSystemObserver {
	function directoryCreated(path:String):Void;
	function fileWritten(path:String, content:Bytes):Void;
	/** A file, or a directory that was empty. */
	function removed(path:String):Void;
	function renamed(path:String, newPath:String):Void;
}

/** A file's bytes, or null content for a directory, with its last modification stamp. */
private class MemoryEntry {
	public final content:Null<Bytes>;
	public final modified:Int;

	public function new(content:Null<Bytes>, modified:Int) {
		this.content = content;
		this.modified = modified;
	}
}
#end
