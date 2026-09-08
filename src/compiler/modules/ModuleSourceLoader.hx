package compiler.modules;

import compiler.Source.SourceFile;
import sys.FileSystem;
import sys.io.File;

/** Lazily materializes source modules from configured filesystem roots. */
class ModuleSourceLoader {
	final roots:Array<String> = [];

	public function new() {}

	public function addRoot(path:String):Void {
		var normalized = normalizeRoot(path);
		if (!FileSystem.exists(normalized) || !FileSystem.isDirectory(normalized))
			throw 'Source root "$path" is not a directory';
		if (roots.indexOf(normalized) < 0)
			roots.push(normalized);
	}

	public function load(name:String, modules:Map<String, ModuleState>):Null<ModuleState> {
		if (modules.exists(name))
			return modules.get(name);
		var relative = name.split(".").join("/") + ".hx";
		for (root in roots) {
			var path = exactPath(root, relative);
			if (path == null)
				continue;
			var state = new ModuleState(name, new SourceFile(path, File.getContent(path)));
			modules.set(name, state);
			return state;
		}
		return null;
	}

	/** Resolve a module path without allowing case-insensitive filesystem aliases. */
	static function exactPath(root:String, relative:String):Null<String> {
		var current = root;
		for (segment in relative.split("/")) {
			if (!FileSystem.exists(current) || !FileSystem.isDirectory(current))
				return null;
			var match:Null<String> = null;
			for (entry in FileSystem.readDirectory(current))
				if (entry == segment) {
					match = entry;
					break;
				}
			if (match == null)
				return null;
			current += "/" + match;
		}
		return current;
	}

	public function copy():ModuleSourceLoader {
		var result = new ModuleSourceLoader();
		for (root in roots)
			result.roots.push(root);
		return result;
	}

	static function normalizeRoot(path:String):String {
		var result = FileSystem.fullPath(path);
		while (result.length > 1 && (StringTools.endsWith(result, "/") || StringTools.endsWith(result, "\\")))
			result = result.substring(0, result.length - 1);
		return result;
	}
}
