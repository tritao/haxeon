package compiler.core;

import haxe.io.Bytes;

/**
 * A file's version: its size, its modification and status-change times at the file system's resolution (nanoseconds where
 * it records them), its inode and device. Equal versions before and after a read mean nothing wrote the file meanwhile, so
 * the read is one state of the file without reading it again to compare.
 */
class FileVersion {
	static inline final BYTES = 32;

	/** Reads of a file a write may overlap before a reader gives up on it. */
	static inline final READ_ATTEMPTS = 4;

	/** The version of the file at `path`, or null when there is none. */
	public static function of(path:String):Null<Bytes> {
		var version = Bytes.alloc(BYTES);
		#if hl
		var text = Bytes.ofString(path), name = Bytes.alloc(text.length + 1);
		name.blit(0, text, 0, text.length);
		name.set(text.length, 0);
		return fileVersion(name.getData(), version.getData()) ? version : null;
		#else
		if (!sys.FileSystem.exists(path))
			return null;
		var stat = sys.FileSystem.stat(path);
		version.setInt32(0, stat.size);
		version.setDouble(8, stat.mtime.getTime());
		version.setDouble(16, stat.ctime.getTime());
		version.setInt32(24, stat.ino);
		version.setInt32(28, stat.dev);
		return version;
		#end
	}

	/** The source at `path`, read once while nothing wrote it; a read a write overlapped is repeated a few times. */
	public static function readSource(path:String):String {
		var text = unchangedRead(path, sys.io.File.getContent, READ_ATTEMPTS);
		if (text == null)
			throw new InternalError('Source changed while being read: $path');
		return text;
	}

	/**
	 * `read(path)` from a moment the file's version held still across, trying `attempts` times; null when a write overlapped
	 * every attempt. A missing file fails as `read` fails on it.
	 */
	public static function unchangedRead(path:String, read:String->String, attempts:Int):Null<String> {
		for (_ in 0...attempts) {
			var before = of(path), text = read(path), after = of(path);
			if (before != null && after != null && before.compare(after) == 0)
				return text;
		}
		return null;
	}

	/** `readSource`, with the version the file held still at while it was read. */
	public static function readVersionedSource(path:String):{text:String, version:Bytes} {
		for (_ in 0...READ_ATTEMPTS) {
			var before = of(path), text = sys.io.File.getContent(path), after = of(path);
			if (before != null && after != null && before.compare(after) == 0)
				return {text: text, version: before};
		}
		throw new InternalError('Source changed while being read: $path');
	}

	#if hl
	@:hlNative("haxeon_runtime", "__sys_file_version")
	static function fileVersion(path:hl.Bytes, version:hl.Bytes):Bool
		return false;
	#end
}
