package project;

import haxe.Json;
import haxe.io.Path;
import build.Target;

class NativeManifest {
	public final sources:Array<String>;
	public final includeDirs:Array<String>;
	public final cmake:Null<NativeCMakeManifest>;
	public final supportedTargets:Array<String>;

	public function new(sources:Array<String>, includeDirs:Array<String>, ?cmake:NativeCMakeManifest, ?supportedTargets:Array<String>) {
		this.sources = sources.copy();
		this.includeDirs = includeDirs.copy();
		this.cmake = cmake;
		this.supportedTargets = supportedTargets == null ? ["host", "android"] : supportedTargets.copy();
	}
}

class NativeCMakeManifest {
	public final source:String;
	public final target:String;
	public final inputs:Array<String>;

	public function new(source:String, target:String, ?inputs:Array<String>) {
		this.source = source;
		this.target = target;
		this.inputs = inputs == null ? [] : inputs.copy();
	}
}

class FfiManifest {
	public final interfaces:Array<String>;
	public final projections:Array<String>;

	public function new(interfaces:Array<String>, projections:Array<String>) {
		this.interfaces = interfaces.copy();
		this.projections = projections.copy();
	}
}

/** Parsed package metadata. Paths remain package-relative until acquisition. */
class PackageManifest {
	public final version:Int;
	public final packageName:String;
	public final packageId:PackageId;
	public final entry:Null<String>;
	public final legacySources:Array<String>;
	public final sourceRoots:Array<String>;
	public final scopeSourceRoots:Bool;
	public final workspace:Array<String>;
	public final target:String;
	public final defines:Array<String>;
	public final outputDir:String;
	public final dependencies:Map<String, PackageDependency>;
	public final native:Null<NativeManifest>;
	public final ffi:Null<FfiManifest>;
	public final androidApplicationId:String;
	public final androidAppLabel:String;
	public final compatibility:PackageCompatibility;

	function new(version:Int, packageName:String, entry:Null<String>, legacySources:Array<String>, sourceRoots:Array<String>, scopeSourceRoots:Bool, workspace:Array<String>,
			target:String, defines:Array<String>, outputDir:String, dependencies:Map<String, PackageDependency>, native:Null<NativeManifest>,
			ffi:Null<FfiManifest>, androidApplicationId:String, androidAppLabel:String, compatibility:PackageCompatibility) {
		this.version = version;
		this.packageName = packageName;
		this.packageId = new PackageId(packageName);
		this.entry = entry;
		this.legacySources = legacySources.copy();
		this.sourceRoots = sourceRoots.copy();
		this.scopeSourceRoots = scopeSourceRoots;
		this.workspace = workspace.copy();
		this.target = target;
		this.defines = defines.copy();
		this.outputDir = outputDir;
		this.dependencies = dependencies;
		this.native = native;
		this.ffi = ffi;
		this.androidApplicationId = androidApplicationId;
		this.androidAppLabel = androidAppLabel;
		this.compatibility = compatibility;
	}

	public static function parse(path:String, content:String):PackageManifest {
		var raw:Dynamic;
		try {
			raw = Json.parse(content);
		} catch (error:Dynamic) {
			throw 'Could not parse $path: ${Std.string(error)}';
		}
		if (!isObject(raw))
			throw '$path must contain a JSON object';
		var rawVersion:Dynamic = Reflect.field(raw, "version"),
			version = rawVersion == null ? 1 : Std.int(rawVersion);
		if (version != 1)
			throw 'Unsupported haxeon.json version "$rawVersion"';
		var packageData:Dynamic = Reflect.field(raw, "package"),
			packageName = packageData == null ? Path.withoutDirectory(Path.directory(path)) : requiredString(packageData, "name", path),
			entry = optionalNullableString(raw, "entry", path),
			legacySources = stringArray(raw, "sources", path, []),
			sourceRoots = stringArray(raw, "sourceRoots", path, ["src"]),
			scopeSourceRoots = optionalBool(raw, "scopeSourceRoots", true, path),
			workspace = stringArray(raw, "workspace", path, []),
			target = optionalString(raw, "target", "host", path),
			defines = stringArray(raw, "defines", path, []),
			outputDir = optionalString(raw, "outputDir", "build", path),
			compatibility = PackageCompatibility.parse(Reflect.field(raw, "compatibility"), path),
			dependencies:Map<String, PackageDependency> = new Map();
		if (packageName.length == 0)
			throw '$path requires a non-empty package name';
		if (sourceRoots.length == 0)
			throw '$path must list at least one path in "sourceRoots"';
		try {
			Target.parse(target);
		} catch (error:Dynamic) {
			throw '$path has an invalid target "$target": ${Std.string(error)}';
		}
		var rawDependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (rawDependencies != null) {
			if (!isObject(rawDependencies))
				throw '$path "dependencies" must be an object';
			var dependencyNames = Reflect.fields(rawDependencies);
			dependencyNames.sort(Reflect.compare);
			for (name in dependencyNames) {
				var dependency:Dynamic = Reflect.field(rawDependencies, name);
				dependencies.set(name, new PackageDependency(new PackageId(name), PackageSourceCodec.parse(dependency, name, '$path dependency "$name"')));
			}
		}
		var nativeData:Dynamic = Reflect.field(raw, "native"),
			native:Null<NativeManifest> = null;
		if (nativeData != null) {
			if (!isObject(nativeData))
				throw '$path "native" must be an object';
			var nativeSources = stringArray(nativeData, "sources", path, []),
				includeDirs = stringArray(nativeData, "includeDirs", path, []),
				supportedTargets = stringArray(nativeData, "targets", path, ["host", "android"]),
				cmakeData:Dynamic = Reflect.field(nativeData, "cmake"),
				cmake:Null<NativeCMakeManifest> = null;
			if (cmakeData != null) {
				if (!isObject(cmakeData))
					throw '$path "native.cmake" must be an object';
				cmake = new NativeCMakeManifest(requiredString(cmakeData, "source", '$path native.cmake'),
					requiredString(cmakeData, "target", '$path native.cmake'), stringArray(cmakeData, "inputs", '$path native.cmake', []));
			}
			if (nativeSources.length == 0 && cmake == null)
				throw '$path "native" requires "sources" or "cmake"';
			if (nativeSources.length > 0 && cmake != null)
				throw '$path "native" cannot combine "sources" and "cmake"';
			for (supportedTarget in supportedTargets)
				try {
					Target.parse(supportedTarget);
				} catch (error:Dynamic) {
					throw '$path "native.targets" contains an invalid target "$supportedTarget": ${Std.string(error)}';
				}
			native = new NativeManifest(nativeSources, includeDirs, cmake, supportedTargets);
		}
		var ffiData:Dynamic = Reflect.field(raw, "ffi"),
			ffi:Null<FfiManifest> = null;
		if (ffiData != null) {
			if (!isObject(ffiData))
				throw '$path "ffi" must be an object';
			var interfaces = stringArray(ffiData, "interfaces", path, []),
				projections = stringArray(ffiData, "projections", path, []);
			if (interfaces.length == 0 && projections.length == 0)
				throw '$path "ffi" requires "interfaces" or "projections"';
			ffi = new FfiManifest(interfaces, projections);
		}
		var android:Dynamic = Reflect.field(raw, "android"),
			androidApplicationId = "org.haxeon.android",
			androidAppLabel = "Haxeon";
		if (android != null) {
			if (!isObject(android))
				throw '$path "android" must be an object';
			androidApplicationId = optionalString(android, "applicationId", androidApplicationId, path);
			androidAppLabel = optionalString(android, "label", androidAppLabel, path);
		}
		return new PackageManifest(version, packageName, entry, legacySources, sourceRoots, scopeSourceRoots, workspace, target, defines, outputDir, dependencies, native, ffi,
			androidApplicationId, androidAppLabel, compatibility);
	}

	static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	static function requiredValueString(value:Dynamic, field:String, path:String):String {
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		if (!isObject(raw))
			throw '$path must contain an object with a "$field" string';
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
			throw '$path "$field" must be a boolean';
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String, fallback:Array<String>):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback.copy();
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>))
			result.push(requiredValueString(item, field, '$path "$field"'));
		return result;
	}
}
