package haxeon.filesystem;

import haxe.Int64;
import haxe.io.Bytes;
import nativekit.ffi.NativeKitFilesystem;
import nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntry;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.platform.NativeKitError;

/** A root-owned regular file handle for bounded positional reads. */
class FileSystemFile {
	static inline final MAX_READ_BYTES = 262144;
	final root:FileSystemRoot;
	final value:Int;
	var closed:Bool = false;

	@:allow(haxeon.filesystem.FileSystemRoot)
	private function new(root:FileSystemRoot, value:Int) {
		this.root = root;
		this.value = value;
	}

	/** Returns current metadata for the pinned file identity. */
	public function info():FileSystemEntry {
		ensureOpen();
		var result = NativeKitFilesystem.nk_filesystem_file_info(value);
		check(result.status, "filesystem.fileInfo");
		return result.out_entry;
	}

	/** Reads at most 256 KiB at a byte offset. */
	public function read(offset:Int64, requestedBytes:Int):Bytes {
		ensureOpen();
		if (offset == null || requestedBytes < 1 || requestedBytes > MAX_READ_BYTES)
			throw "Filesystem read length must be between 1 byte and 256 KiB";
		var result = NativeKitFilesystem.nk_filesystem_file_read(value, offset, requestedBytes);
		check(result.status, "filesystem.fileRead");
		return result.out_bytes;
	}

	/** Releases the native file descriptor. */
	public function close():Void {
		if (closed)
			return;
		var status = NativeKitFilesystem.nk_filesystem_file_close(value);
		closed = true;
		if (status != Result.Ok)
			throw nativeError(status, "filesystem.fileClose");
	}

	function ensureOpen():Void {
		if (closed)
			throw "Filesystem file handle has been closed";
		root.checkLive();
	}

	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw nativeError(status, operation);
	}

	static function nativeError(status:Result, operation:String):NativeKitError
		return new NativeKitError(status, operation, NativeKitFilesystem.nk_filesystem_last_error());
}
