package build.execution;

import haxe.io.Path;
import sys.FileSystem;

/** Directory creation shared by the executor, whose worker threads may create the same path at once. */
class Directories {
	/**
	 * Create `path` and its missing parents. Another thread or process may create a directory
	 * between the existence check and the create, so a failed create is an error only when the
	 * directory still does not exist.
	 */
	public static function ensure(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensure(parent);
		if (!FileSystem.exists(path))
			try {
				FileSystem.createDirectory(path);
			} catch (error:Dynamic) {
				if (!FileSystem.exists(path))
					throw error;
			}
	}
}
