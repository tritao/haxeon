package sys.io;

import haxe.io.Bytes;

#if !wasm
@:hlNative("haxeon_runtime", "__file_write_atomic")
internal extern function writeAtomicBytes(path:String, content:Bytes, replace:Bool):Null<String>;
#else
/** Wasm publishes into the session's in-memory filesystem, where a single store is atomic. */
function writeAtomicBytes(path:String, content:Bytes, replace:Bool):Null<String>
	return runtime.MemoryFileSystem.writeAtomic(path, content, replace);
#end

/**
 * Whole files written so that a reader never sees part of one: the content goes to a temporary file beside the destination,
 * is flushed, and only then replaces it.
 */
class AtomicFile {
	/** Replaces the file `path`, or creates it, with `content`'s UTF-8 bytes, all at once. Throws when it cannot. */
	public static function write(path:String, content:String):Void
		writeBytes(path, Bytes.ofString(content));

	/** Replaces the file `path`, or creates it, with `content`, all at once. Throws when it cannot. */
	public static function writeBytes(path:String, content:Bytes):Void
		publish(path, content, true);

	/** Publish a new file without replacing an existing destination. */
	public static function create(path:String, content:String):Void
		createBytes(path, Bytes.ofString(content));

	/**
	 * Creates the file `path` with `content`, all at once, unless a file is already there. Throws when it cannot, or
	 * when one is.
	 */
	public static function createBytes(path:String, content:Bytes):Void
		publish(path, content, false);

	static function publish(path:String, content:Bytes, replace:Bool):Void {
		var error = writeAtomicBytes(path, content, replace);
		if (error != null) throw 'Could not atomically write "$path": $error';
	}
}
