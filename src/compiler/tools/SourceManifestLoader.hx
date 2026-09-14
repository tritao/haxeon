package compiler.tools;

import compiler.Compiler;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import sys.io.File;

/** Loads a deterministic explicit source manifest into a compiler instance. */
class SourceManifestLoader {
	public static function load(compiler:Compiler, roots:Array<String>, paths:Array<String>, ?packageRoots:Array<PackageSourceRoot>):Void {
		var ordered = paths.copy();
		ordered.sort(Reflect.compare);
		for (path in ordered)
			try {
				compiler.update(projectPath(path, roots, packageRoots), File.getContent(path));
			} catch (error:Dynamic) {
				throw "Could not load compiler source " + path + ": " + Std.string(error);
			}
	}

	public static function projectPath(path:String, roots:Array<String>, ?packageRoots:Array<PackageSourceRoot>):String {
		var normalized = normalizePath(path);
		if (packageRoots != null)
			for (root in packageRoots) {
				var prefix = normalizePath(root.path);
				if (!StringTools.endsWith(prefix, "/"))
					prefix += "/";
				if (StringTools.startsWith(normalized, prefix)) {
					var relative = normalized.substring(prefix.length, normalized.length),
						packagePrefix = root.packageName.split(".").join("/");
					if (!StringTools.startsWith(relative, packagePrefix + "/"))
						relative = packagePrefix + "/" + relative;
					return relative;
				}
			}
		for (root in roots) {
			var prefix = normalizePath(root);
			if (!StringTools.endsWith(prefix, "/"))
				prefix += "/";
			if (StringTools.startsWith(normalized, prefix))
				return normalized.substring(prefix.length, normalized.length);
		}
		return normalized;
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
