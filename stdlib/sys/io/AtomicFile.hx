package sys.io;

@:hlNative("realtime_runtime", "__file_write_atomic")
extern function writeAtomicContent(path:String, content:String, replace:Bool):Bool;

/** Atomic UTF-8 text replacement on POSIX. Unsupported hosts return false.
    Existing permission bits are retained and file data is flushed before
    replacement. Directory metadata durability is not guaranteed. */
class AtomicFile {
	public static function write(path:String, content:String):Bool
		return writeAtomicContent(path, content, true);

	/** Publish a new file without replacing an existing destination. */
	public static function create(path:String, content:String):Bool
		return writeAtomicContent(path, content, false);
}
