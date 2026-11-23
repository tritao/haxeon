package project;

import build.Target;
import compiler.NullSafetyRule;
import compiler.NullSafetyRule.NullSafetyMode;
import compiler.core.InternalError;
import compiler.core.UsageError;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import toml.TomlParser;
import toml.TomlPrinter;

class NativeManifest {
	public final sources:Array<String>;
	public final includeDirs:Array<String>;

	/** Optional language standard for native C and C++ source compilation. */
	public final standard:Null<String>;

	public final cmake:Null<NativeCMakeManifest>;
	public final supportedTargets:Array<String>;

	public function new(sources:Array<String>, includeDirs:Array<String>, ?standard:String, ?cmake:NativeCMakeManifest,
			?supportedTargets:Array<String>) {
		this.sources = sources.copy();
		this.includeDirs = includeDirs.copy();
		this.standard = standard;
		this.cmake = cmake;
		this.supportedTargets = supportedTargets == null ? ["host", "android"] : supportedTargets.copy();
	}
}

class NativeCMakeManifest {
	public final source:String;
	public final target:String;
	public final inputs:Array<String>;

	/** Name of a CMake shared-library target whose runtime file Haxeon exposes. */
	public final library:Null<String>;

	/** Required runtime library names produced by an aggregate CMake target. */
	public final libraries:Array<String>;

	/**
	 * CMake cache settings the package's project is built with (`definitions = { NK_BUILD_SHARED = "ON" }`), wherever it is built:
	 * alone, or in an app's graph (docs/design/PROJECT_BUILDS.md).
	 */
	public final definitions:Map<String, String>;

	public function new(source:String, target:String, ?inputs:Array<String>, ?library:String,
			?libraries:Array<String>, ?definitions:Map<String, String>) {
		this.source = source;
		this.target = target;
		this.inputs = inputs == null ? [] : inputs.copy();
		this.library = library;
		this.libraries = library != null ? [library] : libraries == null ? [] : libraries.copy();
		this.definitions = definitions == null ? [] : definitions.copy();
	}
}

class FfiManifest {
	public final imports:Array<String>;
	public final interfaces:Array<String>;
	public final projections:Array<String>;

	public function new(imports:Array<String>, interfaces:Array<String>, projections:Array<String>) {
		this.imports = imports.copy();
		this.interfaces = interfaces.copy();
		this.projections = projections.copy();
	}
}

/**
 * What makes a project an app: its `[app]` section. An app builds through its runner projects, one per platform it names;
 * a project without the section is a program (docs/design/PROJECT_BUILDS.md).
 */
class AppManifest {
	/** The platforms an app can name, each with a runner project of its own (docs/design/PROJECT_BUILDS.md). */
	public static final PLATFORMS = ["linux", "windows", "macos", "android", "web", "ios"];

	/** The name people see: the window title, the launcher label, the page title. */
	public final name:String;

	/** The reverse-domain identifier: Android's applicationId, the macOS bundle identifier. */
	public final id:String;

	public final version:String;

	/** The icon's image, relative to the manifest, or null for the template's. */
	public final icon:Null<String>;

	/** The platforms the app builds for, each with its runner directory beside the manifest. */
	public final platforms:Array<String>;

	public function new(name:String, id:String, version:String, icon:Null<String>, platforms:Array<String>) {
		this.name = name;
		this.id = id;
		this.version = version;
		this.icon = icon;
		this.platforms = platforms.copy();
	}
}

/**
 * What an instrumented build (`haxeon run --profile=instrument`) probes, from the project's `"instrument"` object.
 * Haxe patterns name functions (`Math`, `haxe.ds.*`); native patterns are globs over source paths relative to the
 * project (`**` crosses directories). Boundary hooks time calls into code the build does not compile.
 */
class InstrumentManifest {
	public final haxeInclude:Array<String>;
	public final haxeExclude:Array<String>;
	public final nativeInclude:Array<String>;
	public final nativeExclude:Array<String>;

	/** Which imported system calls are hooked: "blocking" (the curated set), "none", or that set plus `boundaryExtra`. */
	public final boundaryImports:String;

	/** Further imports to hook, as `module!function` (`kernel32.dll!Sleep`). */
	public final boundaryExtra:Array<String>;

	public final dxgi:Bool;
	public final d3d11:Bool;
	public final vulkan:Bool;

	/** Calls shorter than this many microseconds are dropped as they exit unless a call inside them is kept; 0 keeps every call. */
	public final minCallMicros:Float;

	public static inline final DEFAULT_MIN_CALL_MICROS = 1.0;

	public function new(?haxeInclude:Array<String>, ?haxeExclude:Array<String>, ?nativeInclude:Array<String>,
			?nativeExclude:Array<String>,
			boundaryImports:String = "blocking", ?boundaryExtra:Array<String>, dxgi:Bool = true, d3d11:Bool = true,
			vulkan:Bool = true,
			minCallMicros:Float = DEFAULT_MIN_CALL_MICROS) {
		this.haxeInclude = haxeInclude == null ? ["*"] : haxeInclude.copy();
		this.haxeExclude = haxeExclude == null ? [] : haxeExclude.copy();
		this.nativeInclude = nativeInclude == null ? ["**"] : nativeInclude.copy();
		this.nativeExclude = nativeExclude == null ? [] : nativeExclude.copy();
		this.boundaryImports = boundaryImports;
		this.boundaryExtra = boundaryExtra == null ? [] : boundaryExtra.copy();
		this.dxgi = dxgi;
		this.d3d11 = d3d11;
		this.vulkan = vulkan;
		this.minCallMicros = minCallMicros;
	}
}

/**
 * Parsed package metadata, from a project's haxeon.toml or haxeon.json: one schema, the TOML file's tables being the JSON file's
 * objects (docs/reference/MANIFEST.md). Paths remain package-relative until acquisition.
 */
class PackageManifest {
	public final version:Int;
	public final packageName:String;
	public final packageId:PackageId;
	public final entry:Null<String>;
	public final legacySources:Array<String>;
	public final sourceRoots:Array<String>;

	/** Source roots intentionally outside this package's namespace, even when scoped roots are enabled. */
	public final unscopedSourceRoots:Array<String>;

	public final scopeSourceRoots:Bool;
	public final workspace:Array<String>;
	public final target:String;
	public final defines:Array<String>;

	/** Explicit project choice; `false` builds with `--no-inline`, null keeps the default (inlining on). */
	public final inlineEnabled:Null<Bool>;

	/** The package's null-safety mode (`nullSafety`): Off when the manifest says nothing, as for a Haxelib package without one. */
	public final nullSafety:NullSafetyMode;

	/**
	 * Rules stated beside the package's mode, as a Haxe command line's `--macro nullSafety(...)` states them; only a program's
	 * manifest made in memory (`program`) has any.
	 */
	public final nullSafetyRules:Array<NullSafetyRule>;

	public final outputDir:String;
	public final dependencies:Map<String, PackageDependency>;
	public final native:Null<NativeManifest>;
	public final ffi:Null<FfiManifest>;
	public final androidApplicationId:String;
	public final androidAppLabel:String;
	public final compatibility:PackageCompatibility;

	/** The instrumented build's scope; the defaults instrument everything. */
	public final instrument:InstrumentManifest;

	/** The `[app]` section, which makes the project an app; null for a program. */
	public final app:Null<AppManifest>;

	function new(version:Int, packageName:String, entry:Null<String>, legacySources:Array<String>,
			sourceRoots:Array<String>,
			unscopedSourceRoots:Array<String>, scopeSourceRoots:Bool, workspace:Array<String>, target:String,
			defines:Array<String>, outputDir:String,
			dependencies:Map<String, PackageDependency>, native:Null<NativeManifest>, ffi:Null<FfiManifest>,
			androidApplicationId:String,
			androidAppLabel:String, compatibility:PackageCompatibility, inlineEnabled:Null<Bool>,
			nullSafety:NullSafetyMode, nullSafetyRules:Array<NullSafetyRule>, ?instrument:InstrumentManifest,
			?app:AppManifest) {
		this.version = version;
		this.packageName = packageName;
		this.packageId = new PackageId(packageName);
		this.entry = entry;
		this.legacySources = legacySources.copy();
		this.sourceRoots = sourceRoots.copy();
		this.unscopedSourceRoots = unscopedSourceRoots.copy();
		this.scopeSourceRoots = scopeSourceRoots;
		this.workspace = workspace.copy();
		this.target = target;
		this.defines = defines.copy();
		this.inlineEnabled = inlineEnabled;
		this.nullSafety = nullSafety;
		this.nullSafetyRules = nullSafetyRules.copy();
		this.outputDir = outputDir;
		this.dependencies = dependencies;
		this.native = native;
		this.ffi = ffi;
		this.androidApplicationId = androidApplicationId;
		this.androidAppLabel = androidAppLabel;
		this.compatibility = compatibility;
		this.instrument = instrument == null ? new InstrumentManifest() : instrument;
		this.app = app;
	}

	/** The manifest `haxeon init` writes and every lookup prefers. */
	public static inline final TOML_NAME = "haxeon.toml";

	/** The original manifest format, still read everywhere a TOML one is. */
	public static inline final JSON_NAME = "haxeon.json";

	/** Whether a file named `name` is a project manifest. */
	public static function isManifestName(name:String):Bool
		return name == TOML_NAME || name == JSON_NAME;

	/**
	 * The manifest in `directory`: its haxeon.toml or its haxeon.json, or null when it has neither. A directory with both is a usage
	 * error, as nothing says which one is the project.
	 */
	public static function find(directory:String):Null<String> {
		var toml = Path.join([directory, TOML_NAME]),
			json = Path.join([directory, JSON_NAME]),
			hasToml = FileSystem.exists(toml),
			hasJson = FileSystem.exists(json);
		if (hasToml && hasJson)
			throw new UsageError('$directory has both $TOML_NAME and $JSON_NAME; keep one');
		return hasToml ? toml : hasJson ? json : null;
	}

	/** `find`, else where a new project's manifest goes (its haxeon.toml), the path a missing project is reported at. */
	public static function pathIn(directory:String):String {
		var found = find(directory);
		return found != null ? found : Path.join([directory, TOML_NAME]);
	}

	/** The objects and arrays a manifest holds: TOML for a `.toml` file, else JSON. Syntax errors say where. */
	public static function decode(path:String, content:String):Dynamic {
		var raw:Dynamic;
		try {
			raw = isToml(path) ? TomlParser.parse(content) : Json.parse(content);
		} catch (error:Dynamic) {
			throw new InternalError('Could not parse $path: ${Std.string(error)}');
		}
		if (!isObject(raw))
			throw new InternalError('$path must contain a JSON object');
		return raw;
	}

	public static function isToml(path:String):Bool
		return Path.extension(path).toLowerCase() == "toml";

	/** The order a written manifest's keys take, the schema's (version, entry, sources, ...); other keys follow alphabetically. */
	static final FIELD_ORDER = [
		"version", "name", "entry", "sources", "sourceRoots", "unscopedSourceRoots", "scopeSourceRoots", "workspace",
		"target",
		"defines", "inline", "nullSafety", "outputDir", "package", "app", "dependencies", "native", "ffi", "android",
		"format",
		"compatibility",
		"instrument"
	];

	/** A manifest's objects (`decode`, or made by `haxeon init`) as a haxeon.toml's text. */
	public static function toToml(raw:Dynamic):String
		return TomlPrinter.print(raw, FIELD_ORDER);

	/**
	 * The haxeon.toml that says what the haxeon.json at `path` says. The result is checked: it must read back to the same values
	 * (a JSON null, which TOML cannot write, means what a missing key means) and to a manifest the loader accepts.
	 */
	public static function migrateToToml(path:String, content:String):String {
		parse(path, content);
		var raw = decode(path, content), text = toToml(raw), tomlPath = Path.withExtension(path, "toml");
		if (!sameValue(raw, TomlParser.parse(text)))
			throw new InternalError('$path cannot be written as TOML without changing it');
		parse(tomlPath, text);
		return text;
	}

	static function sameValue(json:Dynamic, toml:Dynamic):Bool {
		if (Std.isOfType(json, Array)) {
			if (!Std.isOfType(toml, Array))
				return false;
			var left:Array<Dynamic> = json, right:Array<Dynamic> = toml;
			if (left.length != right.length)
				return false;
			for (index in 0...left.length)
				if (!sameValue(left[index], right[index]))
					return false;
			return true;
		}
		if (isObject(json) && !Std.isOfType(json, String)) {
			if (!isObject(toml) || Std.isOfType(toml, String))
				return false;
			var fields = [for (field in Reflect.fields(json)) if (Reflect.field(json, field) != null) field];
			if (fields.length != Reflect.fields(toml).length)
				return false;
			for (field in fields)
				if (!Reflect.hasField(toml, field)
					|| !sameValue(Reflect.field(json, field), Reflect.field(toml, field)))
					return false;
			return true;
		}
		return json == toml;
	}

	public static function parse(path:String, content:String):PackageManifest {
		var raw = decode(path, content),
			rawVersion:Dynamic = Reflect.field(raw, "version"),
			version = rawVersion == null ? 1 : Std.int(rawVersion);
		if (version != 1)
			throw new InternalError('$path has an unsupported version "$rawVersion" (the manifest format is version 1)');
		var packageData:Dynamic = Reflect.field(raw, "package"),
			packageName = packageData == null
				? Path.withoutDirectory(Path.directory(path)) : requiredString(packageData, "name", path),
			entry = optionalNullableString(raw, "entry", path),
			legacySources = stringArray(raw, "sources", path, []),
			sourceRoots = stringArray(raw, "sourceRoots", path, ["src"]),
			unscopedSourceRoots = stringArray(raw, "unscopedSourceRoots", path, []),
			scopeSourceRoots = optionalBool(raw, "scopeSourceRoots", true, path),
			workspace = stringArray(raw, "workspace", path, []),
			target = optionalString(raw, "target", "host", path),
			defines = stringArray(raw, "defines", path, []),
			inlineEnabled:Null<Bool> = Reflect.hasField(raw, "inline") ? optionalBool(raw, "inline", true, path) : null,
			outputDir = optionalString(raw, "outputDir", "build", path),
			compatibility = PackageCompatibility.parse(Reflect.field(raw, "compatibility"), path),
			dependencies:Map<String, PackageDependency> = new Map();
		if (packageName.length == 0)
			throw new InternalError('$path requires a non-empty package name');
		if (sourceRoots.length == 0)
			throw new InternalError('$path must list at least one path in "sourceRoots"');
		for (sourceRoot in unscopedSourceRoots)
			if (sourceRoots.indexOf(sourceRoot) < 0)
				throw new InternalError('$path "unscopedSourceRoots" must name roots listed in "sourceRoots"');
		try {
			Target.parse(target);
		} catch (error:Dynamic) {
			throw new InternalError('$path has an invalid target "$target": ${Std.string(error)}');
		}
		var rawDependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (rawDependencies != null) {
			if (!isObject(rawDependencies))
				throw new InternalError('$path "dependencies" must be an object');
			var dependencyNames = Reflect.fields(rawDependencies);
			dependencyNames.sort(Reflect.compare);
			for (name in dependencyNames) {
				var dependency:Dynamic = Reflect.field(rawDependencies, name);
				dependencies.set(name, new PackageDependency(new PackageId(name),
					PackageSourceCodec.parse(dependency, name, '$path dependency "$name"')));
			}
		}
		var nativeData:Dynamic = Reflect.field(raw, "native"),
			native:Null<NativeManifest> = null;
		if (nativeData != null) {
			if (!isObject(nativeData))
				throw new InternalError('$path "native" must be an object');
			var nativeSources = stringArray(nativeData, "sources", path, []),
				includeDirs = stringArray(nativeData, "includeDirs", path, []),
				standard = optionalNullableString(nativeData, "std", path),
				supportedTargets = stringArray(nativeData, "targets", path, ["host", "android"]),
				cmakeData:Dynamic = Reflect.field(nativeData, "cmake"),
				cmake:Null<NativeCMakeManifest> = null;
			if (cmakeData != null) {
				if (!isObject(cmakeData))
					throw new InternalError('$path "native.cmake" must be an object');
				var library = optionalNullableString(cmakeData, "library", '$path native.cmake'),
					libraries = stringArray(cmakeData, "libraries", '$path native.cmake', []);
				if (Reflect.hasField(cmakeData, "libraries")) {
					if (library != null)
						throw new InternalError('$path native.cmake cannot combine "library" and "libraries"');
					if (libraries.length == 0)
						throw new InternalError('$path native.cmake "libraries" must not be empty');
				}
				var names = library == null ? libraries : [library],
					seen = new Map<String, Bool>();
				for (name in names) {
					if (name.indexOf("/") >= 0 || name.indexOf("\\") >= 0 || name == "." || name == "..")
						throw new InternalError('$path native.cmake requires library names without path components');
					if (seen.exists(name))
						throw new InternalError('$path native.cmake contains duplicate library "$name"');
					seen.set(name, true);
				}
				cmake = new NativeCMakeManifest(requiredString(cmakeData, "source", '$path native.cmake'),
					requiredString(cmakeData, "target", '$path native.cmake'),
					stringArray(cmakeData, "inputs", '$path native.cmake', []), library, libraries,
					cmakeDefinitions(cmakeData, '$path native.cmake'));
			}
			if (nativeSources.length == 0 && cmake == null)
				throw new InternalError('$path "native" requires "sources" or "cmake"');
			if (nativeSources.length > 0 && cmake != null)
				throw new InternalError('$path "native" cannot combine "sources" and "cmake"');
			for (supportedTarget in supportedTargets)
				try {
					Target.parse(supportedTarget);
				} catch (error:Dynamic) {
					throw new InternalError('$path "native.targets" contains an invalid target "$supportedTarget": ${Std.string(error)}');
				}
			native = new NativeManifest(nativeSources, includeDirs, standard, cmake, supportedTargets);
		}
		var ffiData:Dynamic = Reflect.field(raw, "ffi"),
			ffi:Null<FfiManifest> = null;
		if (ffiData != null) {
			if (!isObject(ffiData))
				throw new InternalError('$path "ffi" must be an object');
			var imports = stringArray(ffiData, "imports", path, []),
				interfaces = stringArray(ffiData, "interfaces", path, []),
				projections = stringArray(ffiData, "projections", path, []);
			if (imports.length == 0 && interfaces.length == 0 && projections.length == 0)
				throw new InternalError('$path "ffi" requires "imports", "interfaces", or "projections"');
			ffi = new FfiManifest(imports, interfaces, projections);
		}
		var android:Dynamic = Reflect.field(raw, "android"),
			androidApplicationId = "org.haxeon.android",
			androidAppLabel = "Haxeon";
		if (android != null) {
			if (!isObject(android))
				throw new InternalError('$path "android" must be an object');
			androidApplicationId = optionalString(android, "applicationId", androidApplicationId, path);
			androidAppLabel = optionalString(android, "label", androidAppLabel, path);
			if (!isAndroidApplicationId(androidApplicationId))
				throw new InternalError('$path "android.applicationId" must be a dotted Java package name, such as "org.example.game"');
		}
		return new PackageManifest(version, packageName, entry, legacySources, sourceRoots, unscopedSourceRoots,
			scopeSourceRoots, workspace, target, defines,
			outputDir, dependencies, native, ffi, androidApplicationId, androidAppLabel, compatibility, inlineEnabled,
			parseNullSafety(raw, path), [], parseInstrument(raw, path), parseApp(raw, packageName, path));
	}

	/** `native.cmake.definitions`: CMake cache variables and their values, both strings. */
	static function cmakeDefinitions(cmake:Dynamic, path:String):Map<String, String> {
		var raw:Dynamic = Reflect.field(cmake, "definitions"), definitions:Map<String, String> = [];
		if (raw == null)
			return definitions;
		if (!isObject(raw))
			throw new UsageError('$path "definitions" must be a table of CMake variables and values');
		for (name in Reflect.fields(raw)) {
			var value:Dynamic = Reflect.field(raw, name);
			if (!~/^[A-Za-z_][A-Za-z0-9_]*$/.match(name) || !Std.isOfType(value, String))
				throw new UsageError('$path "definitions" maps CMake variable names to string values; "$name" does not');
			definitions.set(name, value);
		}
		return definitions;
	}

	/** The `[app]` section: a name (the package's by default), a reverse-domain `id`, a `version`, an `icon` and the `platforms`. */
	static function parseApp(raw:Dynamic, packageName:String, path:String):Null<AppManifest> {
		var app:Dynamic = Reflect.field(raw, "app");
		if (app == null)
			return null;
		if (!isObject(app))
			throw new UsageError('$path "app" must be a table');
		var id = optionalString(app, "id", "", path);
		if (!isAndroidApplicationId(id))
			throw new UsageError('$path "app.id" must be a reverse-domain identifier, such as "com.example.hello"');
		var platforms = stringArray(app, "platforms", path, []);
		if (platforms.length == 0)
			throw new UsageError('$path "app.platforms" must name at least one of ${AppManifest.PLATFORMS.join(", ")}');
		for (platform in platforms)
			if (AppManifest.PLATFORMS.indexOf(platform) < 0)
				throw new UsageError('$path "app.platforms" names "$platform"; the platforms are ${AppManifest.PLATFORMS.join(", ")}');
		var icon:Dynamic = Reflect.field(app, "icon");
		if (icon != null && !Std.isOfType(icon, String))
			throw new UsageError('$path "app.icon" must be a path');
		return new AppManifest(optionalString(app, "name", packageName, path), id,
			optionalString(app, "version", "1.0.0", path),
			icon, platforms);
	}

	/**
	 * The manifest of a program the CLI builds with no manifest file of its own (a script, a Haxe command line's compilation): a host
	 * project with these sources, source roots (absolute) and defines, built into `build` beside where it is resolved.
	 * `scopeSourceRoots: false` lets its roots hold any package, as Haxe's class paths do.
	 */
	public static function program(name:String, entry:String, sources:Array<String>, sourceRoots:Array<String>,
			scopeSourceRoots:Bool, defines:Array<String>, inlineEnabled:Null<Bool>,
			dependencies:Map<String, PackageSource>, ?nullSafetyRules:Array<NullSafetyRule>):PackageManifest {
		var declared:Map<String, PackageDependency> = [];
		for (dependency => source in dependencies)
			declared.set(dependency, new PackageDependency(new PackageId(dependency), source));
		return new PackageManifest(1, name, entry, sources, sourceRoots, [], scopeSourceRoots, [], "host", defines,
			"build",
			declared, null, null, "org.haxeon.android", "Haxeon", new PackageCompatibility(), inlineEnabled,
			NullSafetyMode.Off,
			nullSafetyRules == null ? [] : nullSafetyRules);
	}

	/** A Java package name with at least two parts, as Android requires of an application ID. */
	static function isAndroidApplicationId(value:String):Bool {
		var parts = value.split(".");
		if (parts.length < 2)
			return false;
		for (part in parts) {
			if (part.length == 0 || !isAsciiLetter(part.charCodeAt(0)) && part.charCodeAt(0) != 95)
				return false;
			for (index in 1...part.length) {
				var code = part.charCodeAt(index);
				if (!isAsciiLetter(code) && (code < 48 || code > 57) && code != 95)
					return false;
			}
		}
		return true;
	}

	static function isAsciiLetter(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);

	/** The modes a manifest's `nullSafety` names; `strict-threaded` stays a compiler option, for metadata and command lines. */
	public static final NULL_SAFETY_VALUES = ["strict", "loose", "off", "warn"];

	static function parseNullSafety(raw:Dynamic, path:String):NullSafetyMode {
		var value:Dynamic = Reflect.field(raw, "nullSafety");
		if (value == null)
			return NullSafetyMode.Off;
		var mode = Std.isOfType(value, String)
			&& NULL_SAFETY_VALUES.indexOf(value) >= 0 ? NullSafetyMode.parse(value) : null;
		if (mode == null)
			throw new InternalError('$path "nullSafety" must be one of '
				+ [for (name in NULL_SAFETY_VALUES) '"$name"'].join(", "));
		return mode;
	}

	static function parseInstrument(raw:Dynamic, path:String):Null<InstrumentManifest> {
		var data:Dynamic = Reflect.field(raw, "instrument");
		if (data == null)
			return null;
		if (!isObject(data))
			throw new InternalError('$path "instrument" must be an object');
		function section(name:String):Dynamic {
			var value:Dynamic = Reflect.field(data, name);
			if (value != null && !isObject(value))
				throw new InternalError('$path "instrument.$name" must be an object');
			return value == null ? {} : value;
		}
		var haxe = section("haxe"),
			native = section("native"),
			boundary = section("boundary"),
			context = '$path instrument',
			imports = optionalString(boundary, "imports", "blocking", context);
		if (imports != "blocking" && imports != "none")
			throw new InternalError('$path "instrument.boundary.imports" must be "blocking" or "none"');
		var minCall:Dynamic = Reflect.field(data, "minCallMicros");
		if (minCall != null && (!Std.isOfType(minCall, Float) || (minCall:Float) < 0 || (minCall:Float) > 4000000))
			throw new InternalError('$path "instrument.minCallMicros" must be a number from 0 to 4000000');
		return new InstrumentManifest(stringArray(haxe, "include", context, ["*"]),
			stringArray(haxe, "exclude", context, []),
			stringArray(native, "include", context, ["**"]), stringArray(native, "exclude", context, []), imports,
			stringArray(boundary, "extra", context, []), optionalBool(boundary, "dxgi", true, context),
			optionalBool(boundary, "d3d11", true, context),
			optionalBool(boundary, "vulkan", true, context),
			minCall == null ? InstrumentManifest.DEFAULT_MIN_CALL_MICROS : (minCall:Float));
	}

	static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	static function requiredValueString(value:Dynamic, field:String, path:String):String {
		if (!Std.isOfType(value, String) || (cast value:String).length == 0)
			throw new InternalError('$path requires a non-empty "$field" string');
		return cast value;
	}

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		if (!isObject(raw))
			throw new InternalError('$path must contain an object with a "$field" string');
		return requiredValueString(Reflect.field(raw, field), field, path);
	}

	static function optionalNullableString(raw:Dynamic, field:String, path:String):Null<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return null;
		return requiredValueString(value, field, path);
	}

	static function optionalString(raw:Dynamic, field:String, fallback:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		return value == null ? fallback : requiredValueString(value, field, path);
	}

	static function optionalBool(raw:Dynamic, field:String, fallback:Bool, path:String):Bool {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback;
		if (!Std.isOfType(value, Bool))
			throw new InternalError('$path "$field" must be a boolean');
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String, fallback:Array<String>):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback.copy();
		if (!Std.isOfType(value, Array))
			throw new InternalError('$path "$field" must be an array of strings');
		var result:Array<String> = [];
		for (item in (cast value:Array<Dynamic>))
			result.push(requiredValueString(item, field, '$path "$field"'));
		return result;
	}
}
