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

	/**
	 * Materialize the direct source modules in a package for a wildcard import.
	 *
	 * A package is not itself a compiler module, so resolving `pkg.*` cannot use
	 * the normal single-module lookup. Keep this operation shallow: nested
	 * packages are separate namespaces and must be requested explicitly.
	 */
	public function loadPackage(packageName:String, modules:Map<String, ModuleState>):Array<ModuleState> {
		var result:Array<ModuleState> = [],
			seen:Map<String, Bool> = [];
		for (name => state in modules)
			if (StringTools.startsWith(name, packageName + ".")) {
				var suffix = name.substring(packageName.length + 1);
				if (suffix.indexOf(".") < 0 && !seen.exists(name)) {
					seen.set(name, true);
					result.push(state);
				}
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
			if (relativePackage != null && relativePackage.length > 0)
				directory += "/" + relativePackage.split(".").join("/");
			if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
				continue;
			var entries = FileSystem.readDirectory(directory);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				if (!StringTools.endsWith(entry, ".hx"))
					continue;
				var moduleName = packageName + "." + entry.substring(0, entry.length - 3);
				if (seen.exists(moduleName))
					continue;
				var state = load(moduleName, modules);
				if (state != null) {
					seen.set(moduleName, true);
					result.push(state);
				}
			}
		}
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
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
