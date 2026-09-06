package compiler.tools;

import compiler.modules.Compiler;
import sys.io.File;

/** Loads a deterministic source manifest into a compiler instance. */
class BootstrapSources {
	public static function load(compiler:Compiler, roots:Array<String>, paths:Array<String>):Void {
		var ordered = paths.copy();
		ordered.sort(Reflect.compare);
		for (path in ordered)
			try {
				compiler.update(projectPath(path, roots), File.getContent(path));
			} catch (error:Dynamic) {
				throw "Could not load bootstrap source " + path + ": " + Std.string(error);
			}
	}

	public static function projectPath(path:String, roots:Array<String>):String {
		var normalized = normalizePath(path);
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
