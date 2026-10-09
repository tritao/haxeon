package haxeon.filesystem;

import nativekit.ffi.NativeKitFilesystem;
import nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntry;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.platform.NativeKitError;

/** Native directory cursor owned by a root. */
class FileSystemDirectory {
	final root:FileSystemRoot;
	final value:Int;
	var closed:Bool = false;

	@:allow(haxeon.filesystem.FileSystemRoot)
	private function new(root:FileSystemRoot, value:Int) {
		this.root = root;
		this.value = value;
	}

	/** Reads one entry, returning null at end. Invalid UTF-8 names have a null name. */
	public function next():Null<FileSystemDirectoryEntry> {
		ensureOpen();
		var result = NativeKitFilesystem.nk_filesystem_directory_next(value);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "filesystem.directoryNext",
				NativeKitFilesystem.nk_filesystem_last_error());
		if (result.out_end)
			return null;
		var name:Null<String> = result.out_entry.get_name_unsupported() != 0 ? null : result.name.toString();
		return new FileSystemDirectoryEntry(name, result.out_entry);
	}

	public function close():Void {
		if (closed)
			return;
		var status = NativeKitFilesystem.nk_filesystem_directory_close(value);
		closed = true;
		if (status != Result.Ok)
			throw new NativeKitError(status, "filesystem.directoryClose",
				NativeKitFilesystem.nk_filesystem_last_error());
	}

	function ensureOpen():Void {
		if (closed)
			throw "Filesystem directory cursor has been closed";
		root.checkLive();
	}
}

/** Metadata for one native directory entry. */
class FileSystemDirectoryEntry {
	public final name:Null<String>;
	public final metadata:FileSystemEntry;

	public function new(name:Null<String>, metadata:FileSystemEntry) {
		this.name = name;
		this.metadata = metadata;
	}
}
