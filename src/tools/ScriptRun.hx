package tools;

import build.execution.ContentDigest;
import compiler.core.InternalError;
import haxe.io.Bytes;
import haxe.io.Path;
import project.PackageManifest;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon script.hx [arguments]` (or `haxeon run script.hx ...`): build and run one Haxe file, as `dotnet run app.cs` does.
 *
 * A script is a program the CLI makes a project for in memory (ProgramProject), built in a cache directory of its own
 * (`HAXEON_SCRIPT_CACHE`, else `~/.haxeon/cache/scripts/<digest of the script's path>`), and then built and run like any
 * other: the file is the project's one source and its directory the source root its imports resolve in (the folder its package
 * starts in, when the script declares one and lives in its folders), so modules beside it
 * can be imported but other scripts there are not compiled. A manifest (`haxeon.toml` or `haxeon.json`) beside the script makes
 * that project a path dependency, with its source roots and dependencies. The incremental build and the artifact cache make a second run cost a
 * launch. A first line `#!/usr/bin/env haxeon` makes the file executable where the shell reads such lines. A script's cache is
 * removed after 30 days without a run.
 */
class ScriptRun {
	/** Whether `argument` names a script: a file whose name ends in `.hx`. */
	public static function isScript(argument:String):Bool
		return StringTools.endsWith(argument, ".hx");

	/** The project `script` is built as. */
	public static function program(script:String):ProgramProject {
		if (!FileSystem.exists(script) || FileSystem.isDirectory(script))
			throw new InternalError('Script not found: $script');
		var path = Path.normalize(FileSystem.fullPath(script)),
			directory = Path.directory(path),
			module = Path.withoutExtension(Path.withoutDirectory(path));
		// The file's name is its module's, dashes and all (as the program cases' are): an entry module is never imported by name.
		if (module == "" || module.indexOf(".") >= 0)
			throw new InternalError('A script needs a name before ".hx" with no other dots: ${Path.withoutDirectory(path)}');
		var packagePath = declaredPackage(File.getContent(path)),
			root = packageRoot(directory, packagePath),
			entry = root == directory ? module : packagePath + "." + module,
			dependencies:Map<String, project.PackageSource> = [],
			neighbour = PackageManifest.find(directory);
		if (neighbour != null)
			dependencies.set(PackageManifest.parse(neighbour, File.getContent(neighbour)).packageName,
				project.PackageSource.Path(directory));
		return new ProgramProject(ProgramProject.directory("scripts", "HAXEON_SCRIPT_CACHE",
			ContentDigest.makeHex(Bytes.ofString(path)).substr(0, 16)),
			PackageManifest.program("script-" + module.toLowerCase().split("_").join("-"), entry, [path], [root],
			true, [],
			null, dependencies), null, entry);
	}

	/** The package a script declares (`package a.b;` before any other declaration), or null. */
	static function declaredPackage(source:String):Null<String> {
		var declaration =
			~/^(?:\s+|\/\/[^\n]*|\/\*(?:[^*]|\*(?!\/))*\*\/|#![^\n]*)*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;/;
		return declaration.match(source) ? declaration.matched(1) : null;
	}

	/**
	 * The source root of a script in `directory` that declares `packagePath`: the directory its package's folders start in, as a
	 * project's source root would be, so the script's modules and their positions (`trace`, stack traces) carry the package path.
	 * A script whose folders do not spell its package keeps its own directory.
	 */
	static function packageRoot(directory:String, packagePath:Null<String>):String {
		if (packagePath == null)
			return directory;
		var folders = directory.split("/"), parts = packagePath.split(".");
		if (parts.length >= folders.length || folders.slice(folders.length - parts.length).join("/") != parts.join("/"))
			return directory;
		return folders.slice(0, folders.length - parts.length).join("/");
	}
}
