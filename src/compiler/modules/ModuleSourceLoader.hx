package compiler.modules;

import compiler.core.FileVersion;
import compiler.core.InternalError;
import compiler.core.Source.SourceFile;
import sys.FileSystem;

/** Lazily materializes source modules from configured filesystem roots. */
class ModuleSourceLoader {
	static final caseSensitiveFileSystem:Bool = Sys.systemName() != "Windows" && Sys.systemName() != "Mac";

	final roots:Array<{path:String, packagePrefix:Null<String>, isStandardLibrary:Bool}> = [];
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
			throw new InternalError('Source root "$path" is not a directory');
		addRootMapping(normalized, null, false);
	}

	/** Register the compiler-owned standard library root; sources loaded from it carry trusted provenance. */
	public function addStandardLibraryRoot(path:String):Void {
		var normalized = normalizeRoot(path);
		if (!FileSystem.exists(normalized) || !FileSystem.isDirectory(normalized))
			throw new InternalError('Standard library source root "$path" is not a directory');
		addRootMapping(normalized, null, true);
	}

	/**
	 * The portable package that ships beside the standard library (`lib/haxeon-io` next to `stdlib`), which both builds of the compiler
	 * compile. It is part of the standard library for every purpose, and absent in a checkout that has not got it.
	 */
	public function addPortableLibraryRoot(standardLibraryPath:String):Void {
		var trimmed = standardLibraryPath;
		while (trimmed.length > 1 && (StringTools.endsWith(trimmed, "/") || StringTools.endsWith(trimmed, "\\")))
			trimmed = trimmed.substr(0, trimmed.length - 1);
		var portable = haxe.io.Path.join([haxe.io.Path.directory(trimmed), "lib", "haxeon-io"]);
		if (FileSystem.exists(portable) && FileSystem.isDirectory(portable))
			addStandardLibraryRoot(portable);
	}

	public function addPackageRoot(packageName:String, path:String):Void {
		if (packageName == null || packageName.length == 0)
			throw new InternalError("Package source root requires a package name");
		var normalized = normalizeRoot(path);
		if (!FileSystem.exists(normalized) || !FileSystem.isDirectory(normalized))
			throw new InternalError('Package source root "$path" is not a directory');
		addRootMapping(normalized, packageName, false);
	}

	function addRootMapping(path:String, packagePrefix:Null<String>, isStandardLibrary:Bool):Void {
		for (root in roots)
			if (root.path == path && root.packagePrefix == packagePrefix) {
				root.isStandardLibrary = root.isStandardLibrary || isStandardLibrary;
				return;
			}
		roots.push({path: path, packagePrefix: packagePrefix, isStandardLibrary: isStandardLibrary});
		missing.clear();
		listings.clear();
	}

	/**
	 * The module `name`, read from the one root that holds it. A module held by two roots is an error: which file wins would
	 * depend on the order of the roots, and a file added to an earlier root would silently replace the module.
	 */
	public function load(name:String, modules:Map<String, ModuleState>):Null<ModuleState> {
		if (modules.exists(name))
			return modules.get(name);
		if (missing.exists(name))
			return null;
		var relative = name.split(".").join("/") + ".hx";
		var found:Null<{path:String, text:String, standard:Bool}> = null;
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
			var text = FileVersion.readSource(path);
			// A file is the module its package declaration names: under a package-scoped root, "Runner.hx" declaring
			// `package app` is app.Runner, not a root-package Runner that a plain root would also reach.
			if (declaresOther(text, packageOf(name)))
				continue;
			// The standard library overrides Haxe's std by design, so a second copy beside it is not a second root.
			if (found != null && found.path != path && !found.standard && !root.isStandardLibrary)
				throw new InternalError('Module "$name" is in two source roots: ${found.path} and $path');
			if (found == null)
				found = {path: path, text: text, standard: root.isStandardLibrary};
		}
		if (found == null) {
			missing.set(name, true);
			return null;
		}
		var state = new ModuleState(name, new SourceFile(found.path, found.text, found.standard));
		modules.set(name, state);
		return state;
	}

	/** Uses a private loader so diagnostic searches cannot populate the build’s lookup caches. */
	public function visitSources(matches:String->Bool, visit:ModuleState->Void):Void {
		var seen:Map<String, ModuleState> = [];
		var loader = copy();
		for (root in loader.roots)
			loader.visitDirectory(root.path, "", root.packagePrefix, matches, seen, visit, []);
	}

	function visitDirectory(directory:String, packageName:String, packageRoot:Null<String>, matches:String->Bool,
			seen:Map<String, ModuleState>, visit:ModuleState->Void, ancestors:Array<String>):Void {
		var real = FileSystem.fullPath(directory);
		if (ancestors.indexOf(real) >= 0)
			return;
		var entries = listing(directory);
		if (entries == null)
			return;
		ancestors.push(real);
		var packageSegment = ~/^[a-z_][a-zA-Z0-9_]*$/,
			moduleFile = ~/^([a-zA-Z_][a-zA-Z0-9_]*)\.hx$/,
			prefix = packageName.length == 0 ? "" : packageName + ".";
		for (entry in entries.order) {
			var path = directory + "/" + entry;
			if (packageSegment.match(entry) && FileSystem.isDirectory(path)) {
				visitDirectory(path, prefix + entry, packageRoot, matches, seen, visit, ancestors);
			} else if (entry != "import.hx" && moduleFile.match(entry) && !FileSystem.isDirectory(path)) {
				var relative = prefix + moduleFile.matched(1);
				var names = packageRoot == null ? [relative] : [packageRoot + "." + relative];
				if (packageRoot != null && StringTools.startsWith(relative, packageRoot + "."))
					names.push(relative);
				try {
					if (!matches(sys.io.File.getContent(path)))
						continue;
					for (name in names)
						if (!seen.exists(name)) {
							var state = load(name, seen);
							if (state != null)
								visit(state);
						}
				} catch (_:haxe.Exception) {
					// An inaccessible, changing or shadowed file cannot provide a reliable suggestion.
				}
			}
		}
		ancestors.pop();
	}

	/** The name of each module the standard library roots hold, sorted, whether or not this build loads it. */
	public function standardModuleNames():Array<String> {
		var seen:Map<String, ModuleState> = [], names:Array<String> = [], loader = copy();
		for (root in loader.roots)
			if (root.isStandardLibrary && root.packagePrefix == null)
				loader.visitDirectory(root.path, "", null, _ -> true, seen, state -> names.push(state.name), []);
		names.sort(Reflect.compare);
		return names;
	}

	/** Whether a standard library root holds module `name`, whether or not this build loads it. */
	public function isStandardModule(name:String):Bool {
		var relative = name.split(".").join("/") + ".hx";
		for (root in roots)
			if (root.isStandardLibrary && root.packagePrefix == null) {
				var path = exactPath(root.path, relative);
				if (path != null && !declaresOther(FileVersion.readSource(path), packageOf(name)))
					return true;
			}
		return false;
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
						text = FileVersion.readSource(path);
					if (declaresOther(text, packageName))
						continue;
					modules.set(moduleName,
						new ModuleState(moduleName, new SourceFile(path, text, root.isStandardLibrary)));
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
			result.roots.push({
				path: root.path,
				packagePrefix: root.packagePrefix,
				isStandardLibrary: root.isStandardLibrary
			});
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
