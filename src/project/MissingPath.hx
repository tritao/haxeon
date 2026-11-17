package project;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The message for a path a manifest names that does not exist, with its likely cause when there is one: a git submodule that was never
 * initialized (as in a fresh worktree) holds the path's directory empty. Package manifests name files in vendored submodules (Audio
 * Lab's native inputs are in vendor/nativekit), and a missing CMake input sends a reader down the wrong trail.
 */
class MissingPath {
	public static function describe(what:String, path:String):String {
		var message = '$what does not exist: $path', submodule = uninitializedSubmodule(path);
		return submodule == null ? message : '$message (${submodule.path} is a git submodule that is not initialized; '
			+ 'run git submodule update --init ${submodule.path} in ${submodule.repository})';
	}

	/** The never-initialized submodule that holds `path`, as its repository's root and its path there; null when there is none. */
	public static function uninitializedSubmodule(path:String):Null<{repository:String, path:String}> {
		// The deepest part of the path that exists, with symlinks resolved: a test tree may link the checkout's vendor/.
		var existing = Path.normalize(path);
		while (existing != "" && existing != "/" && !FileSystem.exists(existing))
			existing = Path.directory(existing);
		if (existing == "" || !FileSystem.isDirectory(existing))
			return null;
		existing = Path.normalize(FileSystem.fullPath(existing));
		// An uninitialized submodule is an empty directory that its enclosing repository's .gitmodules lists.
		if (FileSystem.readDirectory(existing).length > 0)
			return null;
		var repository = Path.directory(existing);
		while (repository != "" && repository != "/") {
			var modules = Path.join([repository, ".gitmodules"]);
			if (FileSystem.exists(modules)) {
				var relative = existing.substr(repository.length + 1);
				for (line in File.getContent(modules).split("\n")) {
					var entry = StringTools.trim(line);
					if (StringTools.startsWith(entry, "path")
						&& StringTools.trim(entry.substr(entry.indexOf("=") + 1)) == relative
						&& StringTools.trim(entry.substr(0, entry.indexOf("="))) == "path")
						return {repository: repository, path: relative};
				}
				return null;
			}
			repository = Path.directory(repository);
		}
		return null;
	}
}
