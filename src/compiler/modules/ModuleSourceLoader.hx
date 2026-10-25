package compiler.modules;

import compiler.Source.SourceFile;
import sys.FileSystem;
import sys.io.File;

/** Lazily materializes source modules from configured filesystem roots. */
class ModuleSourceLoader {
	static final caseSensitiveFileSystem:Bool = Sys.systemName() != "Windows" && Sys.systemName() != "Mac";

	final roots:Array<{path:String, packagePrefix:Null<String>}> = [];
	// Names no root holds a module for. Import resolution asks for the same missing names (a declaration path, then each
	// parent) many times, each a file probe in every root. A copy starts empty, so each compile request probes again.
	final missing:Map<String, Bool> = [];
	// Directory listings, read once per loader: the case-exact lookup would otherwise list a directory for every path
	// segment of every probe. Null marks a path that is not a readable directory. Like `missing`, a copy starts empty.
	final listings:Map<String, Null<DirectoryListing>> = [];

	/** How many directories this loader has listed, for tests. */
	public var listingReads(default, null):Int = 0;

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
		missing.clear();
		listings.clear();
	}

	public function load(name:String, modules:Map<String, ModuleState>):Null<ModuleState> {
		if (modules.exists(name))
			return modules.get(name);
		if (missing.exists(name))
			return null;
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
			var text = File.getContent(path);
			// A file is the module its package declaration names: under a package-scoped root, "Runner.hx" declaring
			// `package app` is app.Runner, not a root-package Runner that a plain root would also reach.
			if (declaresOther(text, packageOf(name)))
				continue;
			var state = new ModuleState(name, new SourceFile(path, text));
			modules.set(name, state);
			return state;
		}
		missing.set(name, true);
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
			var listing = listing(directory);
			if (listing == null)
				continue;
			for (entry in listing.order) {
				if (!StringTools.endsWith(entry, ".hx") || entry == "import.hx")
					continue;
				var basename = entry.substring(0, entry.length - 3);
				if (basename.length == 0)
					continue;
				var moduleName = packageName.length == 0 ? basename : packageName + "." + basename;
				if (!modules.exists(moduleName)) {
					var path = directory + "/" + entry,
						text = File.getContent(path);
					if (declaresOther(text, packageName))
						continue;
					modules.set(moduleName, new ModuleState(moduleName, new SourceFile(path, text)));
				}
				if (result.indexOf(moduleName) < 0)
					result.push(moduleName);
			}
		}
		result.sort(Reflect.compare);
		return result;
	}

	/** Whether `text` declares a package other than `expected` (a file without a declaration is taken as written). */
	static function declaresOther(text:String, expected:String):Bool {
		var declared = declaredPackage(text);
		return declared.length > 0 && declared != expected;
	}

	static function packageOf(moduleName:String):String {
		var dot = moduleName.lastIndexOf(".");
		return dot < 0 ? "" : moduleName.substring(0, dot);
	}

	/** The package a source declares (its leading `package a.b;`, after comments), or "" for the root package. */
	static function declaredPackage(text:String):String {
		var index = 0, length = text.length;
		while (index < length) {
			var code = text.charCodeAt(index);
			if (code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code || code == 0xFEFF) {
				index++;
			} else if (code == "/".code && index + 1 < length && text.charCodeAt(index + 1) == "/".code) {
				while (index < length && text.charCodeAt(index) != "\n".code)
					index++;
			} else if (code == "/".code && index + 1 < length && text.charCodeAt(index + 1) == "*".code) {
				var end = text.indexOf("*/", index + 2);
				index = end < 0 ? length : end + 2;
			} else {
				break;
			}
		}
		if (text.substr(index, 7) != "package")
			return "";
		var after = index + 7;
		if (after < length) {
			var next = text.charCodeAt(after);
			if (next != " ".code && next != "\t".code && next != "\n".code && next != "\r".code && next != ";".code)
				return ""; // an identifier such as `packageName`, not the keyword
		}
		var end = text.indexOf(";", after);
		return end < 0 ? "" : StringTools.trim(text.substring(after, end));
	}

	/** The entries of a directory, listed at most once per loader; null when it is missing, not a directory or unreadable. */
	function listing(directory:String):Null<DirectoryListing> {
		if (listings.exists(directory))
			return listings.get(directory);
		var result:Null<DirectoryListing> = null;
		if (FileSystem.exists(directory) && FileSystem.isDirectory(directory)) {
			listingReads++;
			try {
				var order = FileSystem.readDirectory(directory);
				var names:Map<String, Bool> = [];
				for (entry in order)
					names.set(entry, true);
				result = {order: order, names: names};
			} catch (_:Dynamic) {}
		}
		listings.set(directory, result);
		return result;
	}

	/** Resolve a module path without allowing case-insensitive filesystem aliases. */
	function exactPath(root:String, relative:String):Null<String> {
		if (caseSensitiveFileSystem) {
			var direct = root + "/" + relative;
			return FileSystem.exists(direct) ? direct : null;
		}
		var current = root;
		for (segment in relative.split("/")) {
			var entries = listing(current);
			if (entries == null || !entries.names.exists(segment))
				return null;
			current += "/" + segment;
		}
		return current;
	}

	function exactDirectory(root:String, relative:String):Null<String> {
		if (relative.length == 0)
			return root;
		if (caseSensitiveFileSystem) {
			var direct = root + "/" + relative;
			return FileSystem.exists(direct) && FileSystem.isDirectory(direct) ? direct : null;
		}
		var current = root;
		for (segment in relative.split("/")) {
			var entries = listing(current);
			if (entries == null || !entries.names.exists(segment))
				return null;
			current += "/" + segment;
		}
		return listing(current) == null ? null : current;
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

/** A directory's entries in readDirectory order, with a name set for case-exact membership tests. */
private typedef DirectoryListing = {
	final order:Array<String>;
	final names:Map<String, Bool>;
}
