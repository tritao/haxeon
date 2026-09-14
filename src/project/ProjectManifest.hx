package project;

import haxe.Json;
import haxe.io.Path;

class NativeManifest {
	public final sources:Array<String>;
	public final includeDirs:Array<String>;

	public function new(sources:Array<String>, includeDirs:Array<String>) {
		this.sources = sources.copy();
		this.includeDirs = includeDirs.copy();
	}
}

/** Parsed manifest data. All paths remain package-relative at this layer. */
class ProjectManifest {
	public final version:Int;
	public final packageName:String;
	public final entry:Null<String>;
	public final legacySources:Array<String>;
	public final sourceRoots:Array<String>;
	public final target:String;
	public final defines:Array<String>;
	public final outputDir:String;
	public final dependencies:Map<String, String>;
	public final native:Null<NativeManifest>;
	public final androidApplicationId:String;
	public final androidAppLabel:String;

	function new(version:Int, packageName:String, entry:Null<String>, legacySources:Array<String>, sourceRoots:Array<String>, target:String,
			defines:Array<String>, outputDir:String, dependencies:Map<String, String>, native:Null<NativeManifest>, androidApplicationId:String,
			androidAppLabel:String) {
		this.version = version;
		this.packageName = packageName;
		this.entry = entry;
		this.legacySources = legacySources.copy();
		this.sourceRoots = sourceRoots.copy();
		this.target = target;
		this.defines = defines.copy();
		this.outputDir = outputDir;
		this.dependencies = dependencies;
		this.native = native;
		this.androidApplicationId = androidApplicationId;
		this.androidAppLabel = androidAppLabel;
	}

	public static function parse(path:String, content:String):ProjectManifest {
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
			target = optionalString(raw, "target", "host", path),
			defines = stringArray(raw, "defines", path, []),
			outputDir = optionalString(raw, "outputDir", "build", path),
			dependencies:Map<String, String> = new Map();
		if (packageName.length == 0)
			throw '$path requires a non-empty package name';
		if (sourceRoots.length == 0)
			throw '$path must list at least one path in "sourceRoots"';
		if (target != "host" && target != "wasm32" && target != "android")
			throw '$path target must be "host", "wasm32", or "android"';
		var rawDependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (rawDependencies != null) {
			if (!isObject(rawDependencies))
				throw '$path "dependencies" must be an object';
			var dependencyNames = Reflect.fields(rawDependencies);
			dependencyNames.sort(Reflect.compare);
			for (name in dependencyNames) {
				var dependency:Dynamic = Reflect.field(rawDependencies, name);
				if (!isObject(dependency))
					throw '$path dependency "$name" must be an object with a local "path"';
				dependencies.set(name, requiredString(dependency, "path", '$path dependency "$name"'));
			}
		}
		var nativeData:Dynamic = Reflect.field(raw, "native"),
			native:Null<NativeManifest> = null;
		if (nativeData != null) {
			if (!isObject(nativeData))
				throw '$path "native" must be an object';
			var nativeSources = stringArray(nativeData, "sources", path, []),
				includeDirs = stringArray(nativeData, "includeDirs", path, []);
			if (nativeSources.length == 0)
				throw '$path "native.sources" must contain at least one C source';
			native = new NativeManifest(nativeSources, includeDirs);
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
		return new ProjectManifest(version, packageName, entry, legacySources, sourceRoots, target, defines, outputDir, dependencies, native,
			androidApplicationId, androidAppLabel);
	}

	static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		if (!isObject(raw))
			throw '$path must contain an object with a "$field" string';
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function optionalNullableString(raw:Dynamic, field:String, path:String):Null<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return null;
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path "$field" must be a non-empty string';
		return cast value;
	}

	static function optionalString(raw:Dynamic, field:String, fallback:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback;
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path "$field" must be a non-empty string';
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String, fallback:Array<String>):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback.copy();
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (cast item : String).length == 0)
				throw '$path "$field" must contain only non-empty strings';
			result.push(cast item);
		}
		return result;
	}
}
