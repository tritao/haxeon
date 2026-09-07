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
			var path = root + "/" + relative;
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path))
				continue;
			var state = new ModuleState(name, new SourceFile(path, File.getContent(path)));
			modules.set(name, state);
			return state;
		}
		return null;
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
