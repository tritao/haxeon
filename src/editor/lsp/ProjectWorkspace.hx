package editor.lsp;

import compiler.service.LanguageService;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.ds.ReadOnlyArray;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class HaxeProjectConfiguration {
	public final id:String;
	public final scopeId:String;
	public final file:String;
	public final classPaths:ReadOnlyArray<String>;
	public final entries:ReadOnlyArray<String>;
	public final defines:ReadOnlyArray<String>;
	public final libraries:ReadOnlyArray<String>;

	public function new(file:String, classPaths:Array<String>, entries:Array<String>, defines:Array<String>, libraries:Array<String>) {
		this.file = file;
		this.classPaths = sortedCopy(classPaths);
		this.entries = sortedCopy(entries);
		this.defines = sortedCopy(defines);
		this.libraries = sortedCopy(libraries);
		scopeId = Sha256.encode([
			file,
			this.classPaths.join("|"),
			this.entries.join("|"),
			this.libraries.join("|")
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
	final compilerPathByDisk:Map<String, String> = [];
	final diskPathByCompiler:Map<String, String> = [];
	final sourceRoots:Array<String> = [];
	final workspaceRootPaths:Array<String> = [];
	var preferredConfigurationId:Null<String>;

	public function new() {}

	public function initialize(params:Dynamic, service:LanguageService):Void {
		for (root in workspaceRoots(params))
			workspaceRootPaths.push(root);
		discover(service, _ -> false);
	}

	public function reload(service:LanguageService, isOpen:String->Bool):Void {
		var previous:Map<String, String> = [];
		for (path => compilerPath in compilerPathByDisk)
			previous.set(path, compilerPath);
		configurations.resize(0);
		errors.resize(0);
		sourceRoots.resize(0);
		diskSources.clear();
		compilerPathByDisk.clear();
		diskPathByCompiler.clear();
		for (path => compilerPath in previous)
			if (isOpen(path)) {
				compilerPathByDisk.set(path, compilerPath);
				diskPathByCompiler.set(compilerPath, path);
			}
		discover(service, isOpen);
		for (path => compilerPath in previous)
			if (!diskSources.exists(path) && !isOpen(path))
				service.remove(compilerPath);
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
		return name == "haxe.json" || StringTools.endsWith(name, ".hxml");
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
		if (preferredConfigurationId != null)
			for (configuration in configurations)
				if (configuration.id == preferredConfigurationId)
					return configuration;
		var normalized = normalize(path), matches = [
			for (configuration in configurations)
				if (configuration.owns(normalized)) configuration
		];
		matches.sort(function(left, right) {
			var leftDepth = longestOwningPath(left, normalized),
				rightDepth = longestOwningPath(right, normalized);
			return leftDepth == rightDepth ? Reflect.compare(left.id, right.id) : rightDepth - leftDepth;
		});
		return matches.length == 0 ? (configurations.length == 1 ? configurations[0] : null) : matches[0];
	}

	public static function pathFromUri(uri:String):String
		return uriPath(uri);

	function discover(service:LanguageService, isOpen:String->Bool):Void {
		var configFiles:Array<String> = [];
		for (root in workspaceRootPaths)
			if (FileSystem.exists(root) && FileSystem.isDirectory(root))
				for (name in FileSystem.readDirectory(root))
					if (name == "haxe.json" || StringTools.endsWith(name, ".hxml"))
						configFiles.push(Path.join([root, name]));
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
		if (configurations.length == 0)
			for (root in workspaceRootPaths)
				sourceRoots.push(root);
		else
			for (configuration in configurations)
				for (classPath in configuration.classPaths)
					if (sourceRoots.indexOf(classPath) < 0)
						sourceRoots.push(classPath);
		sourceRoots.sort(Reflect.compare);
		for (root in sourceRoots)
			loadSources(root, service, isOpen);
	}

	public function restore(path:String, service:LanguageService):Bool {
		var normalized = normalize(path), source = diskSources.get(normalized);
		if (source != null) {
			service.update(compilerPath(path), source);
			return true;
		} else if (compilerPathByDisk.exists(normalized)) {
			service.remove(compilerPath(path));
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
				if (name == ".git" || name == "node_modules" || name == "build" || name == "out" || name == "vendor")
					continue;
				var path = normalize(Path.join([directory, name]));
				if (FileSystem.isDirectory(path))
					pending.push(path);
				else if (StringTools.endsWith(name, ".hx")) {
					var source = File.getContent(path),
						compilerPath = relativePath(root, path);
					var existing = diskPathByCompiler.get(compilerPath);
					if (existing != null && existing != path) {
						errors.push('Conflicting module identity $compilerPath: $existing and $path');
						continue;
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
