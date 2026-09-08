package sys.io;

import haxe.io.Bytes;

@:hlNative("realtime_runtime", "__file_write_atomic")
extern function writeAtomicBytes(path:String, content:Bytes, replace:Bool):Null<String>;

/** Durable whole-file publication. The destination is changed only after all
    bytes have been written and flushed. */
class AtomicFile {
	public static function write(path:String, content:String):Void
		writeBytes(path, Bytes.ofString(content));

	public static function writeBytes(path:String, content:Bytes):Void
		publish(path, content, true);

	/** Publish a new file without replacing an existing destination. */
	public static function create(path:String, content:String):Void
		createBytes(path, Bytes.ofString(content));

	public static function createBytes(path:String, content:Bytes):Void
		publish(path, content, false);

	static function publish(path:String, content:Bytes, replace:Bool):Void {
		var error = writeAtomicBytes(path, content, replace);
		if (error != null) throw 'Could not atomically write "$path": $error';
	}
}
