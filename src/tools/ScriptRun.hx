package tools;

import build.execution.ContentDigest;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
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
 * `#!/usr/bin/env haxeon` makes the file executable where the shell reads such lines.
 */
class ScriptRun {
	/** Whether `argument` names a script: a file whose name ends in `.hx`. */
	public static function isScript(argument:String):Bool
		return StringTools.endsWith(argument, ".hx");

	/** The `run` arguments that build and run `script` with `runtimeArguments`, after writing its project. */
	public static function runArguments(script:String, runtimeArguments:Array<String>):Array<String> {
		if (!FileSystem.exists(script) || FileSystem.isDirectory(script))
			throw 'Script not found: $script';
		var path = Path.normalize(FileSystem.fullPath(script)),
			directory = Path.directory(path),
			module = Path.withoutExtension(Path.withoutDirectory(path));
		if (!~/^[A-Za-z_][A-Za-z0-9_]*$/.match(module))
			throw 'A script\'s file name is its module name, so it must be an identifier: $module (use underscores, not dashes)';
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
		return ["--project", manifestPath, "--"].concat(runtimeArguments);
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
