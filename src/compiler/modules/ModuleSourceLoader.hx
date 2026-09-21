package compiler.modules;

import compiler.Source.SourceFile;
import sys.FileSystem;
import sys.io.File;

/** Lazily materializes source modules from configured filesystem roots. */
class ModuleSourceLoader {
	static final caseSensitiveFileSystem:Bool = Sys.systemName() != "Windows" && Sys.systemName() != "Mac";

	final roots:Array<{path:String, packagePrefix:Null<String>}> = [];

	public function new() {}

	public function addRoot(path:String):Void {
		var normalized = normalizeRoot(path);
		if (!FileSystem.exists(normalized) || !FileSystem.isDirectory(normalized))
			throw 'Source root "$path" is not a directory';
		addRootMapping(normalized, null);
	}

	public function addPackageRoot(packageName:String, path:String):Void {
		if (packageName == null || packageName.length == 0)
			throw "Package source root requires a package name";
		var normalized = normalizeRoot(path);
		if (!FileSystem.exists(normalized) || !FileSystem.isDirectory(normalized))
			throw 'Package source root "$path" is not a directory';
		addRootMapping(normalized, packageName);
	}

	function addRootMapping(path:String, packagePrefix:Null<String>):Void {
		for (root in roots)
			if (root.path == path && root.packagePrefix == packagePrefix)
				return;
		roots.push({path: path, packagePrefix: packagePrefix});
	}

	public function load(name:String, modules:Map<String, ModuleState>):Null<ModuleState> {
		if (modules.exists(name))
			return modules.get(name);
		var relative = name.split(".").join("/") + ".hx";
		for (root in roots) {
			var candidates = [relative];
			if (root.packagePrefix != null) {
				var prefix = root.packagePrefix + ".";
				if (StringTools.startsWith(name, prefix))
					candidates.push(name.substr(prefix.length).split(".").join("/") + ".hx");
				else
					continue;
			}
			var path:Null<String> = null;
			for (candidate in candidates) {
				path = exactPath(root.path, candidate);
				if (path != null)
					break;
			}
			if (path == null)
				continue;
			var state = new ModuleState(name, new SourceFile(path, File.getContent(path)));
			modules.set(name, state);
			return state;
		}
		return null;
	}

	/** Materialize all source modules directly contained by a package. */
	public function loadPackage(packageName:String, modules:Map<String, ModuleState>):Array<String> {
		var result:Array<String> = [];
		var prefix = packageName.length == 0 ? "" : packageName + ".";
		for (moduleName in modules.keys())
			if (StringTools.startsWith(moduleName, prefix)) {
				var nestedName = moduleName.substr(prefix.length);
				if (nestedName.length > 0 && nestedName.indexOf(".") < 0)
					result.push(moduleName);
			}
		for (root in roots) {
			var relativePackage:Null<String> = packageName;
			if (root.packagePrefix != null) {
				var prefix = root.packagePrefix + ".";
				if (packageName == root.packagePrefix)
					relativePackage = "";
				else if (StringTools.startsWith(packageName, prefix))
					relativePackage = packageName.substr(prefix.length);
				else
					continue;
			}
			var directory = root.path;
			if (relativePackage != null && relativePackage.length > 0) {
				var relativePath = relativePackage.split(".").join("/");
				var resolved = exactDirectory(root.path, relativePath);
				if (resolved == null)
					continue;
				directory = resolved;
			}
			if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
				continue;
			for (entry in FileSystem.readDirectory(directory)) {
				if (!StringTools.endsWith(entry, ".hx") || entry == "import.hx")
					continue;
				var basename = entry.substring(0, entry.length - 3);
				if (basename.length == 0)
					continue;
				var moduleName = packageName.length == 0 ? basename : packageName + "." + basename;
				if (!modules.exists(moduleName)) {
					var path = directory + "/" + entry;
					modules.set(moduleName, new ModuleState(moduleName, new SourceFile(path, File.getContent(path))));
				}
				if (result.indexOf(moduleName) < 0)
					result.push(moduleName);
			}
		}
		result.sort(Reflect.compare);
		return result;
	}

	/** Resolve a module path without allowing case-insensitive filesystem aliases. */
	static function exactPath(root:String, relative:String):Null<String> {
		if (caseSensitiveFileSystem) {
			var direct = root + "/" + relative;
			return FileSystem.exists(direct) ? direct : null;
		}
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

	static function exactDirectory(root:String, relative:String):Null<String> {
		if (relative.length == 0)
			return root;
		if (caseSensitiveFileSystem) {
			var direct = root + "/" + relative;
			return FileSystem.exists(direct) && FileSystem.isDirectory(direct) ? direct : null;
		}
		var current = root;
		for (segment in relative.split("/")) {
			if (!FileSystem.exists(current) || !FileSystem.isDirectory(current))
				return null;
			var match:Null<String> = null;
			for (entry in FileSystem.readDirectory(current))
				if (entry == segment && FileSystem.isDirectory(current + "/" + entry)) {
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
			result.roots.push({path: root.path, packagePrefix: root.packagePrefix});
		return result;
	}

	static function normalizeRoot(path:String):String {
		var result = FileSystem.fullPath(path);
		while (result.length > 1 && (StringTools.endsWith(result, "/") || StringTools.endsWith(result, "\\")))
			result = result.substring(0, result.length - 1);
		return result;
	}
}
