package editor.lsp;

import compiler.service.LanguageService;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.ds.ReadOnlyArray;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import project.ProjectDiscovery;

class HaxeProjectConfiguration {
	public final id:String;
	public final scopeId:String;
	public final file:String;
	public final classPaths:ReadOnlyArray<String>;
	public final entries:ReadOnlyArray<String>;
	public final defines:ReadOnlyArray<String>;
	public final libraries:ReadOnlyArray<String>;
	public final ffi:compiler.Compiler.FfiConfiguration;
	public final ffiIdentity:String;

	public function new(file:String, classPaths:Array<String>, entries:Array<String>, defines:Array<String>, libraries:Array<String>, ?ffi:compiler.Compiler.FfiConfiguration) {
		this.ffi = ffi == null ? new compiler.Compiler.FfiConfiguration() : ffi;
		ffiIdentity = Sha256.encode(haxe.Json.stringify({interfaces: this.ffi.interfaceSources(), projections: this.ffi.projectionSources()}));
		this.file = file;
		this.classPaths = sortedCopy(classPaths);
		this.entries = sortedCopy(entries);
		this.defines = sortedCopy(defines);
		this.libraries = sortedCopy(libraries);
		scopeId = Sha256.encode([
			file,
			this.classPaths.join("|"),
			this.entries.join("|"),
			this.libraries.join("|"),
			ffiIdentity
		].join("\n"));
		id = Sha256.encode(scopeId + "\n" + this.defines.join("|"));
	}

	public function owns(path:String):Bool {
		for (classPath in classPaths) {
			var prefix = StringTools.endsWith(classPath, "/") ? classPath : classPath + "/";
			if (path == classPath || StringTools.startsWith(path, prefix))
				return true;
		}
		return false;
	}

	static function sortedCopy(values:Array<String>):Array<String> {
		var result = values.copy();
		result.sort(Reflect.compare);
		return result;
	}
}

/** Disk-backed project sources kept below open-document overlays. */
class ProjectWorkspace {
	public final configurations:Array<HaxeProjectConfiguration> = [];
	public final errors:Array<String> = [];

	final diskSources:Map<String, String> = [];
	final declaredSourceDirectories:Map<String, Bool> = [];
	final outputDirectories:Map<String, Bool> = [];
	final compilerPathByDisk:Map<String, String> = [];
	final diskPathByCompiler:Map<String, String> = [];
	final sourceRoots:Array<String> = [];
	final unconfiguredSourceRoots:Array<String> = [];
	final workspaceRootPaths:Array<String> = [];
	final documentConfigurations:Map<String, Bool> = [];
	final detachedConfigurations:Map<String, HaxeProjectConfiguration> = [];
	var preferredConfigurationId:Null<String>;

	public function new() {}

	public function initialize(params:Dynamic, service:LanguageService):Void {
		for (root in workspaceRoots(params))
			workspaceRootPaths.push(root);
		discover(service, _ -> false);
	}

	public function changeWorkspaceFolders(added:Array<String>, removed:Array<String>, service:LanguageService, isOpen:String->Bool):Void {
		for (uri in removed) {
			var root = uriPath(uri);
			while (workspaceRootPaths.remove(root)) {}
		}
		for (uri in added) {
			var root = uriPath(uri);
			if (workspaceRootPaths.indexOf(root) < 0)
				workspaceRootPaths.push(root);
		}
		workspaceRootPaths.sort(Reflect.compare);
		reload(service, isOpen);
	}

	public function reload(service:LanguageService, isOpen:String->Bool):Void {
		var previous:Map<String, String> = [];
		for (path => compilerPath in compilerPathByDisk)
			previous.set(path, compilerPath);
		for (path in previous.keys())
			if (isOpen(path)) {
				var configuration = configurationFor(path);
				if (configuration != null)
					detachedConfigurations.set(path, configuration);
			}
		configurations.resize(0);
		errors.resize(0);
		sourceRoots.resize(0);
		unconfiguredSourceRoots.resize(0);
		diskSources.clear();
		declaredSourceDirectories.clear(); outputDirectories.clear();
		compilerPathByDisk.clear();
		diskPathByCompiler.clear();
		for (path => compilerPath in previous)
			if (isOpen(path)) {
				compilerPathByDisk.set(path, compilerPath);
				diskPathByCompiler.set(compilerPath, path);
			}
		discover(service, isOpen);
		for (path in [for (path in detachedConfigurations.keys()) path])
			if (workspaceOwns(path))
				detachedConfigurations.remove(path);
		if (preferredConfigurationId != null) {
			var preferredExists = false;
			for (configuration in configurations)
				if (configuration.id == preferredConfigurationId)
					preferredExists = true;
			if (!preferredExists)
				preferredConfigurationId = null;
		}
		for (path => compilerPath in previous)
			if (!diskSources.exists(path) && !isOpen(path)) {
				var replacement = diskPathByCompiler.get(compilerPath);
				if (replacement == null || replacement == path)
					service.remove(compilerPath);
			}
	}

	public function refresh(path:String, service:LanguageService, open:Bool):Null<String> {
		var normalized = normalize(path),
			compilerPath = compilerPath(normalized);
		if (FileSystem.exists(normalized) && !FileSystem.isDirectory(normalized)) {
			var source = File.getContent(normalized);
			diskSources.set(normalized, source);
			compilerPathByDisk.set(normalized, compilerPath);
			diskPathByCompiler.set(compilerPath, normalized);
			if (!open)
				service.update(compilerPath, source);
		} else {
			diskSources.remove(normalized);
			if (!open)
				service.remove(compilerPath);
		}
		return compilerPath;
	}

	public function isConfiguration(path:String):Bool {
		var name = Path.withoutDirectory(path);
		return name == "haxeon.json" || name == "haxe.json" || StringTools.endsWith(name, ".hxml") || StringTools.endsWith(name, ".hxi") || StringTools.endsWith(name, ".hxmap");
	}

	public function selectConfiguration(id:Null<String>):Bool {
		if (id == null || id.length == 0) {
			preferredConfigurationId = null;
			return true;
		}
		for (configuration in configurations)
			if (configuration.id == id || configuration.file == id) {
				preferredConfigurationId = configuration.id;
				return true;
			}
		return false;
	}

	public function configurationFor(path:String):Null<HaxeProjectConfiguration> {
		var normalized = normalize(path),
			detached = detachedConfigurations.get(normalized);
		if (detached != null)
			return detached;
		if (preferredConfigurationId != null)
			for (configuration in configurations)
				if (configuration.id == preferredConfigurationId)
					return configuration;
		var matches = [
			for (configuration in configurations)
				if (configuration.owns(normalized)) configuration
		];
		matches.sort(function(left, right) {
			var leftDepth = longestOwningPath(left, normalized),
				rightDepth = longestOwningPath(right, normalized);
			return leftDepth == rightDepth ? Reflect.compare(left.id, right.id) : rightDepth - leftDepth;
		});
		if (matches.length > 0)
			return matches[0];
		for (root in unconfiguredSourceRoots)
			if (normalized == root || StringTools.startsWith(normalized, (StringTools.endsWith(root, "/") ? root : root + "/")))
				return null;
		return configurations.length == 1 ? configurations[0] : null;
	}

	public static function pathFromUri(uri:String):String
		return uriPath(uri);

	function discover(service:LanguageService, isOpen:String->Bool):Void {
		var configFiles:Array<String> = [],
			configuredRoots:Map<String, Bool> = [];
		for (root in workspaceRootPaths) {
			var files = nearestConfigurations(root);
			if (files.length > 0) configuredRoots.set(root, true);
			for (file in files) if (configFiles.indexOf(file) < 0) configFiles.push(file);
		}
		for (file in documentConfigurations.keys())
			if (FileSystem.exists(file) && configFiles.indexOf(file) < 0) configFiles.push(file);
		configFiles.sort(Reflect.compare);
		for (file in configFiles)
			try
				configurations.push(parseConfiguration(file))
			catch (failure:Dynamic)
				errors.push('$file: ${Std.string(failure)}');
		for (configuration in configurations) {
			if (configuration.libraries.length > 0)
				errors.push('${configuration.file}: Haxelib dependencies are recorded but not yet resolved by this compiler');
		}
		for (root in workspaceRootPaths)
			if (!configuredRoots.exists(root)) {
				sourceRoots.push(root);
				unconfiguredSourceRoots.push(root);
			}
		for (configuration in configurations)
			for (classPath in configuration.classPaths)
				if (sourceRoots.indexOf(classPath) < 0)
					sourceRoots.push(classPath);
		sourceRoots.sort(Reflect.compare);
		for (root in sourceRoots)
			loadSources(root, service, isOpen);
	}

	/** Discover project ownership from source location, independently of Explorer roots. */
	public function includeDocument(path:String, service:LanguageService, isOpen:String->Bool):Void {
		for (file in nearestConfigurations(Path.directory(normalize(path)))) {
			var known = false;
			for (configuration in configurations) if (configuration.file == file) known = true;
			if (known) continue;
			try {
				var configuration = parseConfiguration(file);
				documentConfigurations.set(file, true);
				configurations.push(configuration);
				for (root in configuration.classPaths)
					if (sourceRoots.indexOf(root) < 0) sourceRoots.push(root);
				sourceRoots.sort(Reflect.compare);
				for (root in configuration.classPaths) loadSources(root, service, isOpen);
			} catch (failure:Dynamic) {
				errors.push('$file: ${Std.string(failure)}');
			}
		}
	}

	/** Nearest directory with configuration wins; overlapping folders share its files. */
	static function nearestConfigurations(start:String):Array<String> {
		var directory = start;
		while (directory.length > 0) {
			var files:Array<String> = [];
			if (FileSystem.exists(directory) && FileSystem.isDirectory(directory))
				for (name in FileSystem.readDirectory(directory))
					if (name == "haxeon.json" || name == "haxe.json" || StringTools.endsWith(name, ".hxml"))
						files.push(normalize(Path.join([directory, name])));
			if (files.length > 0) { files.sort(Reflect.compare); return files; }
			var parent = Path.directory(directory);
			if (parent == directory) break;
			directory = parent;
		}
		return [];
	}

	public function restore(path:String, service:LanguageService):Bool {
		var normalized = normalize(path), source = diskSources.get(normalized);
		if (source != null) {
			service.update(compilerPath(path), source);
			return true;
		} else if (compilerPathByDisk.exists(normalized)) {
			service.remove(compilerPath(path));
			detachedConfigurations.remove(normalized);
			return true;
		}
		return false;
	}

	public function hasDiskSource(path:String):Bool
		return diskSources.exists(normalize(path));

	public function compilerPath(path:String):String {
		var normalized = normalize(path),
			known = compilerPathByDisk.get(normalized);
		if (known != null)
			return known;
		for (root in sourceRoots) {
			var relative = relativePath(root, normalized);
			if (relative != normalized) {
				compilerPathByDisk.set(normalized, relative);
				diskPathByCompiler.set(relative, normalized);
				return relative;
			}
		}
		return path;
	}

	public function diskPath(path:String):String {
		var known = diskPathByCompiler.get(path);
		return known == null ? path : known;
	}

	function parseConfiguration(file:String):HaxeProjectConfiguration {
		return StringTools.endsWith(file, ".hxml") ? parseHxml(file) : parseJson(file);
	}

	function parseHxml(file:String, ?visiting:Map<String, Bool>):HaxeProjectConfiguration {
		if (visiting == null)
			visiting = [];
		if (visiting.exists(file))
			throw 'Cyclic HXML reference: $file';
		visiting.set(file, true);
		var base = Path.directory(file), classPaths = [], entries = [], defines = [], libraries = [], words:Array<String> = [];
		for (line in File.getContent(file).split("\n")) {
			var clean = StringTools.trim(line), comment = clean.indexOf("#");
			if (comment >= 0)
				clean = StringTools.trim(clean.substr(0, comment));
			if (clean.length > 0)
				for (word in ~/\s+/g.split(clean))
					words.push(word);
		}
		var index = 0;
		while (index < words.length) {
			var option = words[index++],
				value = index < words.length ? words[index] : null;
			switch option {
				case "-cp", "--class-path":
					if (value != null) {
						classPaths.push(resolve(base, value));
						index++;
					}
				case "-main", "--main":
					if (value != null) {
						entries.push(value);
						index++;
					}
				case "-D", "--define":
					if (value != null) {
						defines.push(value);
						index++;
					}
				case "-lib", "--library":
					if (value != null) {
						libraries.push(value);
						index++;
					}
				default:
					if (StringTools.startsWith(option, "-cp="))
						classPaths.push(resolve(base, option.substr(4)));
					else if (StringTools.endsWith(option, ".hxml")) {
						var referenced = parseHxml(resolve(base, option), visiting);
						for (path in referenced.classPaths)
							classPaths.push(path);
						for (entry in referenced.entries)
							entries.push(entry);
						for (define in referenced.defines)
							defines.push(define);
						for (library in referenced.libraries)
							libraries.push(library);
					}
			}
		}
		visiting.remove(file);
		if (classPaths.length == 0)
			classPaths.push(base);
		return new HaxeProjectConfiguration(file, classPaths, entries, defines, libraries);
	}

	function parseJson(file:String):HaxeProjectConfiguration {
		if (Path.withoutDirectory(file) == "haxeon.json") {
			// Share validated local package discovery with the build driver. It does
			// not acquire remote dependencies or build native artifacts.
			var resolved = ProjectDiscovery.discover(file),
				roots:Array<String> = [],
				interfaces:Map<String, String> = [], projections:Map<String, String> = [];
			for (value in resolved.packages.packages) {
				outputDirectories.set(resolve(value.root, value.manifest.outputDir), true);
				for (source in value.sources) {
					var directory = Path.directory(source);
					while (directory.length > value.root.length) {
						declaredSourceDirectories.set(normalize(directory), true);
						directory = Path.directory(directory);
					}
				}
				for (root in value.sourceRoots)
					if (roots.indexOf(root) < 0) roots.push(root);
				for (path in value.ffiInterfaces) interfaces.set(path, File.getContent(path));
				for (path in value.ffiProjections) projections.set(path, File.getContent(path));
			}
			var interfacePaths = [for (path in interfaces.keys()) path], projectionPaths = [for (path in projections.keys()) path];
			interfacePaths.sort(Reflect.compare); projectionPaths.sort(Reflect.compare);
			var ffi = new compiler.Compiler.FfiConfiguration(
				compiler.ffi.HxiInterfaceOrder.dependenciesFirst([for (path in interfacePaths) {path: path, text: interfaces.get(path)}]),
				[for (path in projectionPaths) {path: path, text: projections.get(path)}]);
			var defines = resolved.manifest.defines.concat(compiler.tools.CompilerDriver.targetDefines(resolved.manifest.target == "host" ? "hl" : resolved.manifest.target));
			return new HaxeProjectConfiguration(file, roots, resolved.manifest.entry == null ? [] : [resolved.manifest.entry], defines, [], ffi);
		}
		var value:Dynamic = Json.parse(File.getContent(file)),
			base = Path.directory(file),
			classPaths:Array<String> = [],
			entries:Array<String> = [],
			defines:Array<String> = [],
			libraries:Array<String> = [];
		appendStrings(value, "classPath", item -> classPaths.push(resolve(base, item)));
		appendStrings(value, "classPaths", item -> classPaths.push(resolve(base, item)));
		appendStrings(value, "sourcePaths", item -> classPaths.push(resolve(base, item)));
		appendStrings(value, "main", entries.push);
		appendStrings(value, "defines", defines.push);
		appendStrings(value, "libraries", libraries.push);
		if (classPaths.length == 0)
			classPaths.push(base);
		return new HaxeProjectConfiguration(file, classPaths, entries, defines, libraries);
	}

	function loadSources(root:String, service:LanguageService, isOpen:String->Bool):Void {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			errors.push('Source root does not exist: $root');
			return;
		}
		var pending = [root], loaded = 0;
		while (pending.length > 0 && loaded < 10000) {
			var directory = pending.pop(),
				names = FileSystem.readDirectory(directory);
			names.sort(Reflect.compare);
			for (name in names) {
				var path = normalize(Path.join([directory, name]));
				if (name == ".git" || name == "node_modules" || name == "vendor" || outputDirectories.exists(path) ||
					((name == "build" || name == "out") && !declaredSourceDirectories.exists(path))) continue;
				if (FileSystem.isDirectory(path))
					pending.push(path);
				else if (StringTools.endsWith(name, ".hx")) {
					if (preferredSourceRoot(path) != root)
						continue;
					var source = File.getContent(path),
						compilerPath = relativePath(root, path);
					var existing = diskPathByCompiler.get(compilerPath);
					if (existing != null && existing != path) {
						errors.push('Conflicting module identity $compilerPath: $existing and $path');
						continue;
					}
					var previous = compilerPathByDisk.get(path);
					if (previous != null && previous != compilerPath) {
						diskPathByCompiler.remove(previous);
						service.remove(previous);
					}
					diskSources.set(path, source);
					compilerPathByDisk.set(path, compilerPath);
					diskPathByCompiler.set(compilerPath, path);
					if (!isOpen(path))
						service.update(compilerPath, source);
					loaded++;
				}
			}
		}
		if (loaded >= 10000)
			errors.push('Source scan limit reached below $root');
	}

	function preferredSourceRoot(path:String):Null<String> {
		var result:Null<String> = null;
		for (root in sourceRoots)
			if ((path == root || StringTools.startsWith(path, (StringTools.endsWith(root, "/") ? root : root + "/")))
				&& (result == null || root.length > result.length))
				result = root;
		return result;
	}

	function workspaceOwns(path:String):Bool {
		for (root in workspaceRootPaths)
			if (path == root || StringTools.startsWith(path, (StringTools.endsWith(root, "/") ? root : root + "/")))
				return true;
		return false;
	}

	static function appendStrings(value:Dynamic, field:String, append:String->Void):Void {
		var found:Dynamic = Reflect.field(value, field);
		if (Std.isOfType(found, String))
			append(cast found);
		else if (Std.isOfType(found, Array))
			for (item in cast(found, Array<Dynamic>))
				if (Std.isOfType(item, String))
					append(cast item);
	}

	static function workspaceRoots(params:Dynamic):Array<String> {
		var result:Array<String> = [],
			folders:Dynamic = Reflect.field(params, "workspaceFolders");
		if (Std.isOfType(folders, Array))
			for (folder in cast(folders, Array<Dynamic>)) {
				var uri:Dynamic = Reflect.field(folder, "uri");
				if (Std.isOfType(uri, String))
					result.push(uriPath(cast uri));
			}
		var root:Dynamic = Reflect.field(params, "rootUri");
		if (result.length == 0 && Std.isOfType(root, String))
			result.push(uriPath(cast root));
		return result;
	}

	static function resolve(base:String, path:String):String
		return normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));

	static function relativePath(root:String, path:String):String {
		var prefix = StringTools.endsWith(root, "/") ? root : root + "/";
		return StringTools.startsWith(path, prefix) ? path.substr(prefix.length) : path;
	}

	static function longestOwningPath(configuration:HaxeProjectConfiguration, path:String):Int {
		var result = -1;
		for (classPath in configuration.classPaths)
			if (path == classPath || StringTools.startsWith(path, (StringTools.endsWith(classPath, "/") ? classPath : classPath + "/")))
				result = Std.int(Math.max(result, classPath.length));
		return result;
	}

	static function uriPath(uri:String):String
		return normalize(StringTools.startsWith(uri, "file://") ? StringTools.urlDecode(uri.substr(7)) : uri);

	static function normalize(path:String):String
		return StringTools.replace(FileSystem.absolutePath(path), "\\", "/");
}
