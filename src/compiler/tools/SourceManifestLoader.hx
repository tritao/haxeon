package compiler.tools;

import compiler.Compiler;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import sys.FileSystem;
import sys.io.File;

/** Loads a deterministic explicit source manifest into a compiler instance. */
class SourceManifestLoader {
	public static function load(compiler:Compiler, roots:Array<String>, paths:Array<String>, ?packageRoots:Array<PackageSourceRoot>,
			?readSource:String->Null<String>):Void {
		var ordered = paths.copy();
		ordered.sort(Reflect.compare);
		for (path in ordered)
			try {
				var source = readSource == null ? File.getContent(path) : readSource(path);
				if (source != null)
					compiler.update(projectPath(path, roots, packageRoots), source);
			} catch (error:Dynamic) {
				throw "Could not load compiler source " + path + ": " + Std.string(error);
			}
	}

	/**
	 * The path of a source file as its module sees it: relative to the source root it is under. A file and a root match
	 * however each is written (relative to the working directory, absolute, with `.` or `..` segments), so a file given
	 * by absolute path under a relative root still resolves to its module.
	 */
	public static function projectPath(path:String, roots:Array<String>, ?packageRoots:Array<PackageSourceRoot>):String {
		var normalized = normalizePath(path),
			canonicalFile = canonicalPath(path);
		if (packageRoots != null)
			for (root in packageRoots) {
				var prefix = canonicalPath(root.path);
				if (!StringTools.endsWith(prefix, "/"))
					prefix += "/";
				if (StringTools.startsWith(canonicalFile, prefix)) {
					var relative = canonicalFile.substring(prefix.length, canonicalFile.length),
						packagePrefix = root.packageName.split(".").join("/");
					if (!StringTools.startsWith(relative, packagePrefix + "/"))
						relative = packagePrefix + "/" + relative;
					return relative;
				}
			}
		for (root in roots) {
			var prefix = canonicalPath(root);
			if (!StringTools.endsWith(prefix, "/"))
				prefix += "/";
			if (StringTools.startsWith(canonicalFile, prefix))
				return canonicalFile.substring(prefix.length, canonicalFile.length);
		}
		return normalized;
	}

	/** An absolute path with forward slashes and no `.` or `..` segments; a path that does not exist is resolved against the working directory too. */
	static function canonicalPath(path:String):String {
		var normalized = normalizePath(path);
		return normalizePath(haxe.io.Path.normalize(haxe.io.Path.isAbsolute(normalized) ? normalized : FileSystem.absolutePath(normalized)));
	}

	static function normalizePath(path:String):String {
		var result = "";
		for (index in 0...path.length) {
			var code = path.charCodeAt(index);
			result += String.fromCharCode(code == 92 ? 47 : code);
		}
		return result;
	}
}
