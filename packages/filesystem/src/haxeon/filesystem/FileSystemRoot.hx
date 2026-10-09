package haxeon.filesystem;

import nativekit.ffi.NativeKitFilesystem;
import nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntry;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.platform.NativeKitError;

/** A locally granted directory exposed through root-relative metadata calls. */
class FileSystemRoot {
	final value:Int;
	var closed:Bool = false;

	public function new(absolutePath:String) {
		var opened = NativeKitFilesystem.nk_filesystem_root_open(absolutePath);
		check(opened.status, "filesystem.rootOpen");
		value = opened.out_root;
	}

	/** Returns metadata for a canonical slash-separated path relative to this root. */
	public function stat(relativePath:String):FileSystemEntry {
		ensureOpen();
		var result = NativeKitFilesystem.nk_filesystem_stat(value, relativePath);
		check(result.status, "filesystem.stat");
		return result.out_entry;
	}

	/** Opens a bounded native cursor over a root-relative directory. */
	public function openDirectory(relativePath:String):FileSystemDirectory {
		ensureOpen();
		var result = NativeKitFilesystem.nk_filesystem_directory_open(value, relativePath);
		check(result.status, "filesystem.directoryOpen");
		return new FileSystemDirectory(this, result.out_cursor);
	}

	/** Opens one in-root regular file for bounded positional reads. */
	public function openFile(relativePath:String):FileSystemFile {
		ensureOpen();
		var result = NativeKitFilesystem.nk_filesystem_file_open(value, relativePath);
		check(result.status, "filesystem.fileOpen");
		return new FileSystemFile(this, result.out_file);
	}

	/** Revokes this root and invalidates its open cursors. */
	public function close():Void {
		if (closed)
			return;
		var status = NativeKitFilesystem.nk_filesystem_root_close(value);
		closed = true;
		if (status != Result.Ok)
			throw nativeError(status, "filesystem.rootClose");
	}

	@:allow(haxeon.filesystem.FileSystemDirectory)
	@:allow(haxeon.filesystem.FileSystemFile)
	function checkLive():Void
		ensureOpen();

	function ensureOpen():Void {
		if (closed)
			throw "Filesystem root has been closed";
	}

	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw nativeError(status, operation);
	}

	static function nativeError(status:Result, operation:String):NativeKitError
		return new NativeKitError(status, operation, NativeKitFilesystem.nk_filesystem_last_error());
}
