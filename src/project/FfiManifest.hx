package project;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** A source-controlled recipe for one C or C++ header import. */
class FfiImportManifest {
	public final version:Int;
	public final name:String;
	public final language:String;
	public final header:String;
	public final target:Null<String>;
	public final standard:String;
	public final clang:String;
	public final includes:Array<String>;
	public final defines:Array<String>;
	public final compileCommands:Null<String>;
	public final library:Null<String>;
	public final interfaceName:Null<String>;
	public final dependencies:Array<String>;
	public final excludedHeaders:Array<String>;
	public final sourceLabel:Null<String>;
	public final cxxSelections:Array<String>;
	public final trivialValues:Bool;
	public final lifetimes:Bool;
	public final virtualDispatch:Bool;
	public final cxxThunks:Bool;

	/** Maps an owned C++ factory function to its explicit free-function release function. */
	public final cxxOwnership:Map<String, String>;

	public final projection:Bool;

	function new(version:Int, name:String, language:String, header:String, target:Null<String>, standard:String, clang:String, includes:Array<String>,
			defines:Array<String>, compileCommands:Null<String>, library:Null<String>, interfaceName:Null<String>, dependencies:Array<String>,
			excludedHeaders:Array<String>, sourceLabel:Null<String>, cxxSelections:Array<String>, trivialValues:Bool, lifetimes:Bool, virtualDispatch:Bool,
			cxxThunks:Bool, cxxOwnership:Map<String, String>, projection:Bool) {
		this.version = version;
		this.name = name;
		this.language = language;
		this.header = header;
		this.target = target;
		this.standard = standard;
		this.clang = clang;
		this.includes = includes.copy();
		this.defines = defines.copy();
		this.compileCommands = compileCommands;
		this.library = library;
		this.interfaceName = interfaceName;
		this.dependencies = dependencies.copy();
		this.excludedHeaders = excludedHeaders.copy();
		this.sourceLabel = sourceLabel;
		this.cxxSelections = cxxSelections.copy();
		this.trivialValues = trivialValues;
		this.lifetimes = lifetimes;
		this.virtualDispatch = virtualDispatch;
		this.cxxThunks = cxxThunks;
		this.cxxOwnership = cxxOwnership;
		this.projection = projection;
	}

	public static function parse(path:String, content:String):FfiImportManifest {
		var raw:Dynamic;
		try {
			raw = Json.parse(content);
		} catch (error:Dynamic) {
			throw 'Could not parse FFI manifest $path: ${Std.string(error)}';
		}
		if (!isObject(raw))
			throw '$path must contain a JSON object';
		var rawVersion:Dynamic = Reflect.field(raw, "version"),
			version = rawVersion == null ? 1 : Std.int(rawVersion);
		if (version != 1)
			throw 'Unsupported FFI manifest version "$rawVersion" in $path';
		var name = requiredString(raw, "name", path),
			language = optionalString(raw, "language", "c", path),
			header = requiredString(raw, "header", path),
			target = nullableString(raw, "target", path),
			standard = optionalString(raw, "std", language == "c++" ? "c++20" : "c11", path),
			clang = optionalString(raw, "clang", language == "c++" ? "clang++" : "clang", path),
			includes = stringArray(raw, "includes", path),
			defines = stringArray(raw, "defines", path),
			compileCommands = nullableString(raw, "compileCommands", path),
			library = nullableString(raw, "library", path),
			interfaceName = nullableString(raw, "interface", path),
			dependencies = stringArray(raw, "depends", path),
			excludedHeaders = stringArray(raw, "excludeHeaders", path),
			sourceLabel = nullableString(raw, "sourceLabel", path),
			cxxSelections = stringArray(raw, "select", path),
			trivialValues = optionalBool(raw, "cxxTrivialValues", false, path),
			lifetimes = optionalBool(raw, "cxxLifetimes", false, path),
			virtualDispatch = optionalBool(raw, "cxxVirtual", false, path),
			cxxThunks = optionalBool(raw, "cxxThunks", false, path),
			cxxOwnership = stringMap(raw, "cxxOwnership", path),
			projection = optionalBool(raw, "projection", false, path);
		if (language != "c" && language != "c++")
			throw '$path has unsupported FFI language "$language"';
		if (name.indexOf("/") >= 0 || name.indexOf("\\") >= 0 || name == "." || name == "..")
			throw '$path "name" must be a single path-safe artifact name';
		if (language != "c++"
			&& (cxxSelections.length != 0 || trivialValues || lifetimes || virtualDispatch || cxxThunks || cxxOwnership.keys().hasNext()))
			throw '$path uses C++ options but language is "$language"';
		if (projection && library == null)
			throw '$path enables "projection" but has no "library"';
		if (cxxThunks && library == null)
			throw '$path enables "cxxThunks" but has no "library"';
		return new FfiImportManifest(version, name, language, header, target, standard, clang, includes, defines, compileCommands, library, interfaceName,
			dependencies, excludedHeaders, sourceLabel, cxxSelections, trivialValues, lifetimes, virtualDispatch, cxxThunks, cxxOwnership, projection);
	}

	public static function resolve(path:String, packageRoot:String):ResolvedFfiImport {
		var absoluteManifest = FileSystem.fullPath(path),
			config = parse(absoluteManifest, File.getContent(absoluteManifest)),
			base = Path.directory(absoluteManifest);
		return new ResolvedFfiImport(absoluteManifest, packageRoot, config, resolveFile(base, config.header, absoluteManifest, "header"),
			resolveDirectories(base, config.includes, absoluteManifest),
			config.compileCommands == null ? null : resolveFile(base, config.compileCommands, absoluteManifest, "compile commands"),
			resolveFiles(base, config.excludedHeaders, absoluteManifest, "excluded header"));
	}

	static function resolveFile(base:String, value:String, manifestPath:String, kind:String):String {
		var path = Path.normalize(Path.isAbsolute(value) ? value : Path.join([base, value]));
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path))
			throw '$manifestPath $kind does not exist: $path';
		return FileSystem.fullPath(path);
	}

	static function resolveDirectories(base:String, values:Array<String>, manifestPath:String):Array<String> {
		var result:Array<String> = [];
		for (value in values) {
			var path = Path.normalize(Path.isAbsolute(value) ? value : Path.join([base, value]));
			if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
				throw '$manifestPath include directory does not exist: $path';
			result.push(FileSystem.fullPath(path));
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function resolveFiles(base:String, values:Array<String>, manifestPath:String, kind:String):Array<String> {
		var result:Array<String> = [];
		for (value in values)
			result.push(resolveFile(base, value, manifestPath, kind));
		result.sort(Reflect.compare);
		return result;
	}

	static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		var value = nullableString(raw, field, path);
		if (value == null || value.length == 0)
			throw '$path requires a non-empty "$field" string';
		return value;
	}

	static function nullableString(raw:Dynamic, field:String, path:String):Null<String> {
		if (!Reflect.hasField(raw, field) || Reflect.field(raw, field) == null)
			return null;
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String))
			throw '$path "$field" must be a string';
		return cast value;
	}

	static function optionalString(raw:Dynamic, field:String, fallback:String, path:String):String {
		var value = nullableString(raw, field, path);
		return value == null ? fallback : value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String):Array<String> {
		if (!Reflect.hasField(raw, field) || Reflect.field(raw, field) == null)
			return [];
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (cast item : String).length == 0)
				throw '$path "$field" must contain non-empty strings';
			result.push(cast item);
		}
		return result;
	}

	static function stringMap(raw:Dynamic, field:String, path:String):Map<String, String> {
		var result:Map<String, String> = [];
		if (!Reflect.hasField(raw, field) || Reflect.field(raw, field) == null)
			return result;
		var value:Dynamic = Reflect.field(raw, field);
		if (!isObject(value))
			throw '$path "$field" must be an object mapping C++ declarations to release functions';
		for (key in Reflect.fields(value)) {
			var release:Dynamic = Reflect.field(value, key);
			if (key.length == 0 || !Std.isOfType(release, String) || (cast release : String).length == 0)
				throw '$path "$field" must map non-empty declaration names to non-empty release function names';
			result.set(key, cast release);
		}
		return result;
	}

	static function optionalBool(raw:Dynamic, field:String, fallback:Bool, path:String):Bool {
		if (!Reflect.hasField(raw, field) || Reflect.field(raw, field) == null)
			return fallback;
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, Bool))
			throw '$path "$field" must be a boolean';
		return cast value;
	}
}

/** FFI manifest paths resolved against the owning package. */
class ResolvedFfiImport {
	public final manifestPath:String;
	public final packageRoot:String;
	public final config:FfiImportManifest;
	public final header:String;
	public final includes:Array<String>;
	public final compileCommands:Null<String>;
	public final excludedHeaders:Array<String>;

	public function new(manifestPath:String, packageRoot:String, config:FfiImportManifest, header:String, includes:Array<String>,
			compileCommands:Null<String>, excludedHeaders:Array<String>) {
		this.manifestPath = manifestPath;
		this.packageRoot = packageRoot;
		this.config = config;
		this.header = header;
		this.includes = includes.copy();
		this.compileCommands = compileCommands;
		this.excludedHeaders = excludedHeaders.copy();
	}

	public function inputs():Array<String> {
		var result = [manifestPath, header].concat(includes).concat(excludedHeaders);
		if (compileCommands != null)
			result.push(compileCommands);
		result.sort(Reflect.compare);
		return result;
	}
}
