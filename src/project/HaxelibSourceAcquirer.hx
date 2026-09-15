package project;

import build.execution.ProcessRunner;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Imports Haxelib metadata into an immutable Haxeon source-cache entry. */
class HaxelibSourceAcquirer implements SourceAcquirer {
	final cacheRoot:String;
	final archiveRoot:String;

	public function new(cacheRoot:String) {
		this.cacheRoot = Path.normalize(cacheRoot);
		this.archiveRoot = Path.join([Path.directory(this.cacheRoot), "downloads", "haxelib"]);
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Haxelib(name, version):
				var destination = Path.join([cacheRoot, name, version]);
				if (!FileSystem.exists(destination))
					publishArchive(name, version, destination, packageId);
				else if (!FileSystem.isDirectory(destination))
					throw 'Haxelib cache entry for "$packageId" is not a directory: $destination';
				adaptIfNeeded(destination, name, version, packageId);
				new AcquiredSource(FileSystem.fullPath(destination), source, version);
			case _:
				throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the Haxelib acquirer';
		};

	function publishArchive(name:String, version:String, destination:String, packageId:PackageId):Void {
		var archive = Path.join([archiveRoot, '$name-$version.zip']);
		if (!FileSystem.exists(archive))
			archive = Path.join([archiveRoot, '$name-$version.tar.gz']);
		if (!FileSystem.exists(archive))
			throw 'Haxelib package "$name@$version" is not in the Haxeon cache; place its archive at $archive or publish its source directory';
		ensureDirectory(Path.directory(destination));
		var temporary = destination + '.extract-${Std.int(Date.now().getTime())}';
		if (FileSystem.exists(temporary))
			throw 'Temporary Haxelib extraction already exists: $temporary';
		ensureDirectory(temporary);
		var command = StringTools.endsWith(archive, ".zip") ? "unzip" : "tar",
			arguments = command == "unzip" ? ["-q", archive, "-d", temporary] : ["-xzf", archive, "-C", temporary],
			status = ProcessRunner.run(command, arguments, temporary, new Map());
		if (status != 0)
			throw 'Could not extract Haxelib package "$packageId" from $archive';
		var sourceRoot = findManifestRoot(temporary);
		if (sourceRoot == null)
			throw 'Haxelib archive $archive does not contain haxelib.json';
		FileSystem.rename(sourceRoot, destination);
		if (sourceRoot != temporary)
			FileSystem.deleteDirectory(temporary);
	}

	function adaptIfNeeded(root:String, name:String, version:String, packageId:PackageId):Void {
		var manifestPath = Path.join([root, "haxeon.json"]);
		if (FileSystem.exists(manifestPath))
			return;
		var haxelibPath = Path.join([root, "haxelib.json"]);
		if (!FileSystem.exists(haxelibPath))
			throw 'Haxelib cache entry for "$packageId" has neither haxeon.json nor haxelib.json: $root';
		var raw:Dynamic;
		try {
			raw = Json.parse(File.getContent(haxelibPath));
		} catch (error:Dynamic) {
			throw 'Could not parse $haxelibPath: ${Std.string(error)}';
		}
		if (!Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$haxelibPath must contain a JSON object';
		for (field in ["extraParams", "compilerParams", "hxml", "macro"])
			if (hasNonEmptyValue(raw, field))
				throw 'Haxelib package "$packageId" uses unsupported compiler setting "$field"; translate it into Haxeon manifest metadata explicitly';
		var declaredName = requiredString(raw, "name", haxelibPath),
			declaredVersion = requiredString(raw, "version", haxelibPath);
		if (declaredName != name || declaredVersion != version)
			throw 'Haxelib cache entry "$packageId" metadata names $declaredName@$declaredVersion';
		var classPath = optionalString(raw, "classPath", "src", haxelibPath),
			dependencies:Dynamic = {},
			rawDependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (rawDependencies != null) {
			if (!Reflect.isObject(rawDependencies) || Std.isOfType(rawDependencies, Array))
				throw '$haxelibPath "dependencies" must be an object';
			for (dependencyName in Reflect.fields(rawDependencies)) {
				var dependencyVersion:Dynamic = Reflect.field(rawDependencies, dependencyName);
				if (!Std.isOfType(dependencyVersion, String) || (cast dependencyVersion : String).length == 0)
					throw '$haxelibPath dependency "$dependencyName" must have an exact version for reproducible import';
				Reflect.setField(dependencies, dependencyName, {haxelib: dependencyName, version: cast dependencyVersion});
			}
		}
		var generated:Dynamic = {
			version: 1,
			sourceRoots: [classPath],
			dependencies: dependencies
		};
		Reflect.setField(generated, "package", {name: declaredName});
		File.saveContent(manifestPath, Json.stringify(generated, null, "\t") + "\n");
	}

	function findManifestRoot(root:String):Null<String> {
		if (FileSystem.exists(Path.join([root, "haxelib.json"])))
			return root;
		for (entry in FileSystem.readDirectory(root)) {
			var path = Path.join([root, entry]);
			if (FileSystem.isDirectory(path) && FileSystem.exists(Path.join([path, "haxelib.json"])))
				return path;
		}
		return null;
	}

	static function hasNonEmptyValue(raw:Dynamic, field:String):Bool {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return false;
		if (Std.isOfType(value, String))
			return (cast value : String).length > 0;
		if (Std.isOfType(value, Array))
			return (cast value : Array<Dynamic>).length > 0;
		return true;
	}

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function optionalString(raw:Dynamic, field:String, fallback:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback;
		return requiredString(raw, field, path);
	}

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}
}
