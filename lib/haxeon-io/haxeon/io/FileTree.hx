package haxeon.io;

import haxe.io.Path;
import sys.FileSystem;

/** Directory trees on disk. */
class FileTree {
	/**
	 * Deletes `path` and everything under it, and does nothing when it does not exist. A Git checkout is deleted too: Git
	 * writes its objects read-only and Windows deletes no read-only file, so there the tree's read-only attributes are
	 * cleared first.
	 */
	public static function remove(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path) && Sys.systemName() == "Windows")
			Sys.command("attrib", ["-R", StringTools.replace(path, "/", "\\") + "\\*", "/S", "/D"]);
		removeEntries(path);
	}

	static function removeEntries(path:String):Void {
		if (!FileSystem.isDirectory(path)) {
			FileSystem.deleteFile(path);
			return;
		}
		for (entry in FileSystem.readDirectory(path))
			removeEntries(Path.join([path, entry]));
		FileSystem.deleteDirectory(path);
	}
}
