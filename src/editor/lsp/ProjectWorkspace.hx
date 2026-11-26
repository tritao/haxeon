package editor.lsp;

import build.BuildEnvironment;
import build.BuildEnvironment.BuildProfile;
import build.HaxeonProjectBuild;
import build.Target;
import build.TargetLayout;
import compiler.core.FileVersion;
import compiler.core.InternalError;
import compiler.core.TextDigest;
import compiler.service.LanguageService;
import compiler.tools.SourceManifestLoader;
import haxe.Json;
import haxe.ds.ReadOnlyArray;
import haxe.io.Path;
import project.CompilerInputs;
import project.PackageManifest;
import project.ProjectDiscovery;
import project.ShaderInputs;
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
	public final ffi:compiler.ffi.FfiRegistry.FfiConfiguration;
	public final ffiIdentity:String;

	/** The project's null-safety rules, as its build passes them (`CompilerInputs.nullSafety`). */
	public final nullSafety:ReadOnlyArray<compiler.NullSafetyRule>;

	/** The project's packages and their directories, as its build passes them (`CompilerInputs.sourcePackages`). */
	public final sourcePackages:ReadOnlyArray<compiler.SourcePackages.SourcePackage>;

	/** The project's own package when its manifest requires its documentation (`package.documentation`), else null. */
	public final documentedPackage:Null<String>;

	public function new(file:String, classPaths:Array<String>, entries:Array<String>, defines:Array<String>,
			libraries:Array<String>,
			?ffi:compiler.ffi.FfiRegistry.FfiConfiguration, ?nullSafety:Array<compiler.NullSafetyRule>,
			?sourcePackages:Array<compiler.SourcePackages.SourcePackage>, ?documentedPackage:String) {
		this.documentedPackage = documentedPackage;
		this.ffi = ffi == null ? new compiler.ffi.FfiRegistry.FfiConfiguration() : ffi;
		ffiIdentity = TextDigest.sha256(haxe.Json.stringify({
			interfaces: this.ffi.interfaceSources(),
			projections: this.ffi.projectionSources()
		}));
		this.file = file;
		this.classPaths = sortedCopy(classPaths);
		this.entries = sortedCopy(entries);
		this.defines = sortedCopy(defines);
		this.libraries = sortedCopy(libraries);
		this.nullSafety = nullSafety == null ? [] : nullSafety.copy();
		this.sourcePackages = sourcePackages == null ? [] : sourcePackages.copy();
		scopeId = TextDigest.sha256([
			file,
			this.classPaths.join("|"),
			this.entries.join("|"),
			this.libraries.join("|"),
			ffiIdentity
		].join("\n"));
		id = TextDigest.sha256(scopeId + "\n" + this.defines.join("|") + "\n"
			+ [for (rule in this.nullSafety) rule.argument()].join("|") + "\n"
			+ [for (entry in this.sourcePackages) entry.argument() + ":" + entry.friends.join(",")].join("|") + "\n"
			+ (documentedPackage ?? ""));
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
	/**
		Source roots that are a project's own directory, where a directory named `build` or `out` is presumed to hold generated
		output rather than a package: an unconfigured workspace root, a class path that is its configuration's directory (named
		or implied), and a haxeon.json root other than its source folders. A class path below its configuration's directory
		(`-cp src`) is a package root, so `src/build` is the `build` package; outputs there are only those a configuration names
		(`outputDirectories`).
	**/
	final presumedOutputRoots:Map<String, Bool> = [];
	// Source roots whose files belong to a package (`scopeSourceRoots`), by root: its files are modules of that package.
	final packageRootNames:Map<String, String> = [];
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

	public function changeWorkspaceFolders(added:Array<String>, removed:Array<String>, service:LanguageService,
			isOpen:String->Bool):Void {
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
		declaredSourceDirectories.clear();
		outputDirectories.clear();
		presumedOutputRoots.clear();
		packageRootNames.clear();
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
			var source = FileVersion.readSource(normalized);
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
		return PackageManifest.isManifestName(name) || name == "haxe.json" || StringTools.endsWith(name, ".hxml")
			|| StringTools.endsWith(name, ".hxi")
			|| StringTools.endsWith(name, ".hxmap");
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
			if (normalized == root
				|| StringTools.startsWith(normalized, (StringTools.endsWith(root, "/") ? root : root + "/")))
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
			if (files.length > 0)
				configuredRoots.set(root, true);
			for (file in files)
				if (configFiles.indexOf(file) < 0)
					configFiles.push(file);
		}
		for (file in documentConfigurations.keys())
			if (FileSystem.exists(file) && configFiles.indexOf(file) < 0)
				configFiles.push(file);
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
				presumedOutputRoots.set(normalize(root), true);
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
			for (configuration in configurations)
				if (configuration.file == file)
					known = true;
			if (known)
				continue;
			try {
				var configuration = parseConfiguration(file);
				documentConfigurations.set(file, true);
				configurations.push(configuration);
				for (root in configuration.classPaths)
					if (sourceRoots.indexOf(root) < 0)
						sourceRoots.push(root);
				sourceRoots.sort(Reflect.compare);
				for (root in configuration.classPaths)
					loadSources(root, service, isOpen);
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
					if (PackageManifest.isManifestName(name) || name == "haxe.json"
						|| StringTools.endsWith(name, ".hxml"))
						files.push(normalize(Path.join([directory, name])));
			if (files.length > 0) {
				files.sort(Reflect.compare);
				return files;
			}
			var parent = Path.directory(directory);
			if (parent == directory)
				break;
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
		var root = preferredSourceRoot(normalized);
		if (root == null)
			return path;
		var modulePath = modulePath(root, normalized);
		compilerPathByDisk.set(normalized, modulePath);
		diskPathByCompiler.set(modulePath, normalized);
		return modulePath;
	}

	/** The compiler's path of a file under a source root: relative to the root, under its package's directory for a package root. */
	function modulePath(root:String, path:String):String {
		var relative = relativePath(root, path), packageName = packageRootNames.get(root);
		return packageName == null ? relative : SourceManifestLoader.packagePath(relative, packageName);
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
			throw new InternalError('Cyclic HXML reference: $file');
		visiting.set(file, true);
		var base = Path.directory(file),
			classPaths = [],
			entries = [],
			defines = [],
			libraries = [],
			words:Array<String> = [];
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
				// A target the build writes: the directory a file target goes to, or a directory target itself.
				case "-hl", "--hl", "-js", "--js", "-lua", "--lua", "-neko", "--neko", "-python", "--python", "-swf",
					"--swf", "--jvm":
					if (value != null) {
						var directory = Path.directory(resolve(base, value));
						if (directory != normalize(base))
							outputDirectories.set(directory, true);
						index++;
					}
				case "-cpp", "--cpp", "-cs", "--cs", "-java", "--java", "-php", "--php":
					if (value != null) {
						outputDirectories.set(resolve(base, value), true);
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
		presumeProjectDirectoryOutputs(base, classPaths);
		return new HaxeProjectConfiguration(file, classPaths, entries, defines, libraries);
	}

	function parseJson(file:String):HaxeProjectConfiguration {
		if (PackageManifest.isManifestName(Path.withoutDirectory(file))) {
			// Resolved as the build resolves it, with haxeon.lock, but offline: a dependency missing from the source cache is an
			// error to fix with `haxeon install`, never a download the editor starts. Native artifacts are not built here.
			var resolved = ProjectDiscovery.resolve(file, null, true),
				target = Target.parse(resolved.manifest.target),
				inputs = CompilerInputs.of(resolved,
					new TargetLayout(new BuildEnvironment(resolved.root,
					HaxeonProjectBuild.outputDirectory(resolved, false),
					BuildProfile.Debug, target))),
				spelling = new LinkSpelling(Path.directory(file)),
				roots:Array<String> = [],
				interfaces:Map<String, String> = [],
				projections:Map<String, String> = [],
				sourceFolders:Map<String, Bool> = [];
			// Discovery returns native separators and resolves symbolic links; ownership compares
			// normalized paths in the spelling the editor opened the workspace by.
			function local(path:String):String
				return spelling.respell(normalize(path));
			for (value in resolved.packages.packages) {
				var packageRoot = local(value.root);
				outputDirectories.set(resolve(packageRoot, value.manifest.outputDir), true);
				for (source in value.sources) {
					var directory = Path.directory(local(source));
					while (directory.length > packageRoot.length) {
						declaredSourceDirectories.set(directory, true);
						directory = Path.directory(directory);
					}
				}
				for (root in value.sourceRoots.map(local))
					if (root != packageRoot)
						sourceFolders.set(root, true);
			}
			for (root in inputs.roots.map(local))
				if (roots.indexOf(root) < 0)
					roots.push(root);
			for (root in inputs.packageRoots)
				packageRootNames.set(local(root.path), root.packageName);
			for (path in inputs.ffiInterfaces)
				interfaces.set(local(path), File.getContent(path));
			for (path in inputs.ffiProjections)
				projections.set(local(path), File.getContent(path));
			// FFI imports are generated by a build; until one has run, their declarations are missing here.
			var ungenerated = 0;
			for (ffi in inputs.generatedFfi) {
				var projectionRoot = ffi.projectionRoot;
				if (!FileSystem.exists(ffi.interfacePath)
					|| (projectionRoot != null && !FileSystem.exists(projectionRoot))) {
					ungenerated++;
					continue;
				}
				interfaces.set(local(ffi.interfacePath), File.getContent(ffi.interfacePath));
				if (projectionRoot != null && roots.indexOf(local(projectionRoot)) < 0)
					roots.push(local(projectionRoot));
			}
			var generatedShaders = ShaderInputs.output(HaxeonProjectBuild.outputDirectory(resolved, false), target);
			if (ShaderInputs.roots(resolved).length > 0 && FileSystem.exists(ShaderInputs.sources(generatedShaders)))
				roots.push(local(generatedShaders));
			// The manifest names the outputs of its source folders exactly; elsewhere build and out are presumed outputs.
			for (root in roots)
				if (!sourceFolders.exists(root))
					presumedOutputRoots.set(root, true);
			if (ungenerated > 0)
				errors.push('$file: $ungenerated FFI import(s) have not been generated yet; build the project once ("haxeon build")');
			var interfacePaths = [for (path in interfaces.keys()) path],
				projectionPaths = [for (path in projections.keys()) path];
			interfacePaths.sort(Reflect.compare);
			projectionPaths.sort(Reflect.compare);
			var ffi = new compiler.ffi.FfiRegistry
				.FfiConfiguration(compiler.ffi.HxiInterfaceOrder.dependenciesFirst([for (path in interfacePaths)
				{
					path: path,
					text: interfaces.get(path)
				}]), [for (path in projectionPaths) {
					path: path, text: projections.get(path)
				}]);
			var defines = inputs.defines.concat(compiler.tools.CompilerDriver.targetDefines(inputs.target));
			return new HaxeProjectConfiguration(file, roots, inputs.entry == null ? [] : [inputs.entry], defines, [],
				ffi, inputs.nullSafety, inputs.sourcePackages,
				resolved.manifest.documentationRequired ? resolved.rootPackage.name : null);
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
		appendStrings(value, "main", item -> entries.push(item));
		appendStrings(value, "defines", item -> defines.push(item));
		appendStrings(value, "libraries", item -> libraries.push(item));
		if (classPaths.length == 0)
			classPaths.push(base);
		presumeProjectDirectoryOutputs(base, classPaths);
		return new HaxeProjectConfiguration(file, classPaths, entries, defines, libraries);
	}

	/** A class path that is its configuration's own directory is a project directory, where build and out are presumed outputs. */
	function presumeProjectDirectoryOutputs(base:String, classPaths:Array<String>):Void
		for (classPath in classPaths)
			if (normalize(classPath) == normalize(base))
				presumedOutputRoots.set(normalize(classPath), true);

	function loadSources(root:String, service:LanguageService, isOpen:String->Bool):Void {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			errors.push('Source root does not exist: $root');
			return;
		}
		var pending = [root], loaded = 0, presumeOutputs = presumedOutputRoots.exists(normalize(root));
		while (pending.length > 0 && loaded < 10000) {
			var directory = pending.pop(),
				names = FileSystem.readDirectory(directory);
			names.sort(Reflect.compare);
			for (name in names) {
				var path = normalize(Path.join([directory, name]));
				if (name == ".git"
					|| name == "node_modules"
					|| name == "vendor"
					|| outputDirectories.exists(path)
					|| (presumeOutputs && (name == "build" || name == "out")
					&& !declaredSourceDirectories.exists(path)))
					continue;
				if (FileSystem.isDirectory(path))
					pending.push(path);
				else if (StringTools.endsWith(name, ".hx")) {
					if (preferredSourceRoot(path) != root)
						continue;
					var source = FileVersion.readSource(path),
						compilerPath = modulePath(root, path);
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
			if (path == classPath
				|| StringTools.startsWith(path, (StringTools.endsWith(classPath, "/") ? classPath : classPath + "/")))
				result = Std.int(Math.max(result, classPath.length));
		return result;
	}

	static function uriPath(uri:String):String
		return normalize(FileUri.toPath(uri));

	static function normalize(path:String):String
		return StringTools.replace(FileSystem.absolutePath(path), "\\", "/");
}

/**
	Maps a path with its symbolic links resolved back into the spelling of an anchor directory: the deepest
	ancestor of the anchor whose resolved form contains the path names it. A path outside every ancestor keeps
	its resolved form.
**/
private class LinkSpelling {
	final ancestors:Array<{spelled:String, resolved:String}> = [];

	public function new(anchor:String) {
		var directory = anchor;
		// A Windows drive ends the walk: "D:" names the current directory on drive D, not the drive's root, so resolving it
		// would map the drive to wherever the process happens to run.
		while (directory.length > 0 && !~/^[A-Za-z]:\/?$/.match(directory)) {
			if (FileSystem.exists(directory)) {
				var resolved = StringTools.replace(FileSystem.fullPath(directory), "\\", "/");
				if (resolved != directory)
					ancestors.push({spelled: directory, resolved: resolved});
			}
			var parent = Path.directory(directory);
			if (parent == directory)
				break;
			directory = parent;
		}
	}

	public function respell(path:String):String {
		for (ancestor in ancestors)
			if (path == ancestor.resolved)
				return ancestor.spelled;
			else if (StringTools.startsWith(path, ancestor.resolved + "/"))
				return ancestor.spelled + path.substr(ancestor.resolved.length);
		return path;
	}
}
