package tools;

import build.execution.ContentDigest;
import compiler.core.InternalError;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.io.FileTree;
import project.PackageManifest;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon script.hx [arguments]` (or `haxeon run script.hx ...`): build and run one Haxe file, as `dotnet run app.cs` does.
 *
 * A script is a project the CLI writes for it, in a cache directory of its own (`HAXEON_SCRIPT_CACHE`, else
 * `~/.haxeon/cache/scripts/<digest of the script's path>`), and then builds and runs like any other: the file is the
 * project's one source and its directory the source root its imports resolve in, so modules beside it can be imported but
 * other scripts there are not compiled. A `haxeon.json` beside the script makes that project a path dependency, with its
 * source roots and dependencies. The incremental build and the artifact cache make a second run cost a launch. A first line
 * `#!/usr/bin/env haxeon` makes the file executable where the shell reads such lines. A script's cache is removed after
 * 30 days without a run.
 */
class ScriptRun {
	/** Whether `argument` names a script: a file whose name ends in `.hx`. */
	public static function isScript(argument:String):Bool
		return StringTools.endsWith(argument, ".hx");

	/** The `run` arguments that build and run `script` with `runtimeArguments`, after writing its project. */
	public static function runArguments(script:String, runtimeArguments:Array<String>):Array<String> {
		if (!FileSystem.exists(script) || FileSystem.isDirectory(script))
			throw new InternalError('Script not found: $script');
		var path = Path.normalize(FileSystem.fullPath(script)),
			directory = Path.directory(path),
			module = Path.withoutExtension(Path.withoutDirectory(path));
		// The file's name is its module's, dashes and all (as the program cases' are): an entry module is never imported by name.
		if (module == "" || module.indexOf(".") >= 0)
			throw new InternalError('A script needs a name before ".hx" with no other dots: ${Path.withoutDirectory(path)}');
		var projectDirectory = Path.join([cacheRoot(), ContentDigest.makeHex(Bytes.ofString(path)).substr(0, 16)]),
			manifest:Dynamic = {
				version: 1,
				"package": {name: "script-" + module.toLowerCase().split("_").join("-")},
				entry: module,
				sources: [path],
				sourceRoots: [directory],
				target: "host",
				outputDir: "build"
			},
			neighbour = Path.join([directory, "haxeon.json"]);
		if (FileSystem.exists(neighbour)) {
			var name = PackageManifest.parse(neighbour, File.getContent(neighbour)).packageName,
				dependencies = {};
			Reflect.setField(dependencies, name, {path: directory});
			manifest.dependencies = dependencies;
		}
		var manifestPath = Path.join([projectDirectory, "haxeon.json"]),
			content = Json.stringify(manifest, null, "\t") + "\n";
		// Rewritten only when it changes, so an unchanged script keeps its incremental build.
		if (!FileSystem.exists(manifestPath) || File.getContent(manifestPath) != content) {
			FileSystem.createDirectory(projectDirectory);
			File.saveContent(manifestPath, content);
		}
		// When this script last ran, for the pruning of scripts that have not.
		File.saveContent(Path.join([projectDirectory, LAST_RUN]), Std.string(Sys.time()));
		prune(Path.directory(projectDirectory), projectDirectory);
		return ["--project", manifestPath, "--"].concat(runtimeArguments);
	}

	static inline final LAST_RUN = "last-run";

	/** A script's cache is removed after this long without a run: a script run monthly keeps its build. */
	static inline final UNUSED_SECONDS = 30 * 24 * 3600.0;

	/** Removes the caches of scripts that have not run for `UNUSED_SECONDS`, the running one aside. */
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

	static function cacheRoot():String {
		var configured = Sys.getEnv("HAXEON_SCRIPT_CACHE");
		if (configured != null && configured != "")
			return Path.normalize(configured);
		var home = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
		if (home == null || home == "")
			home = Sys.getCwd();
		return Path.join([home, ".haxeon", "cache", "scripts"]);
	}
}
