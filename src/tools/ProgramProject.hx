package tools;

import haxe.io.Path;
import haxeon.io.FileTree;
import project.PackageManifest;
import sys.FileSystem;
import sys.io.File;

/**
 * A program the CLI builds with no manifest of its own: a script (`haxeon script.hx`) or one compilation of a Haxe command
 * line (`haxeon build.hxml`). Its manifest is made in memory (`PackageManifest.program`) and resolved in place, and its build
 * state lives in a directory of a cache the CLI keeps for such programs, named by what identifies the program, so its next
 * build is incremental. A directory not used for `UNUSED_SECONDS` is removed.
 */
class ProgramProject {
	/** The program's directory in its cache: the build goes to `build` below it. No manifest file is written there. */
	public final root:String;

	public final manifest:PackageManifest;

	/** Where the built module is copied (a Haxe command line's `--hl FILE`), or null to leave it in the build. */
	public final publishTo:Null<String>;

	public final scriptModule:Null<String>;

	public function new(root:String, manifest:PackageManifest, ?publishTo:String, ?scriptModule:String) {
		this.scriptModule = scriptModule;
		this.root = root;
		this.manifest = manifest;
		this.publishTo = publishTo;
	}

	/** Where the manifest is placed for resolution; nothing is read from or written to it. */
	public function manifestPath():String
		return Path.join([root, PackageManifest.TOML_NAME]);

	/**
	 * The directory of the program `key` names in the cache `name` (`~/.haxeon/cache/NAME`, or the directory `variable` gives),
	 * created and marked as used now. The cache's other programs that have not been used for `UNUSED_SECONDS` are removed.
	 */
	public static function directory(name:String, variable:Null<String>, key:String):String {
		var root = build.UserCache.directory(name, variable), directory = Path.join([root, key]);
		// Parents too: the first program makes its cache.
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		File.saveContent(Path.join([directory, LAST_RUN]), Std.string(Sys.time()));
		prune(root, directory);
		return directory;
	}

	static inline final LAST_RUN = "last-run";

	/** A program's build is removed after this long without one: a script run monthly keeps its build. */
	static inline final UNUSED_SECONDS = 30 * 24 * 3600.0;

	/** Removes the builds of programs that have not been used for `UNUSED_SECONDS`, the current one aside. */
	static function prune(root:String, current:String):Void {
		var now = Sys.time();
		for (name in FileSystem.readDirectory(root)) {
			var directory = Path.join([root, name]);
			if (directory == current || !FileSystem.isDirectory(directory))
				continue;
			var stamp = Path.join([directory, LAST_RUN]),
				lastRun = FileSystem.exists(stamp)
					? Std.parseFloat(File.getContent(stamp)) : FileSystem.stat(directory).mtime.getTime() / 1000;
			if (Math.isNaN(lastRun) || now - lastRun > UNUSED_SECONDS)
				try
					FileTree.remove(directory)
				catch (_:Dynamic) {} // in use by another run, or already gone: the next run tries again
		}
	}
}
