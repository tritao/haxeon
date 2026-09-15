package project;

import haxe.Json;
import sys.io.File;
import haxe.io.Path;
import sys.FileSystem;
import project.PackageManifest.NativeManifest;

/** Immutable release metadata used by the registry source adapter. */
class RegistryVersion {
	public final version:String;
	public final checksum:String;
	public final yanked:Bool;
	public final compatibility:PackageCompatibility;

	public function new(version:String, checksum:String, yanked:Bool, compatibility:PackageCompatibility) {
		this.version = version;
		this.checksum = checksum;
		this.yanked = yanked;
		this.compatibility = compatibility;
	}
}

class RegistryIndex {
	public final packages:Map<String, Array<RegistryVersion>>;

	public function new(packages:Map<String, Array<RegistryVersion>>) {
		this.packages = packages;
	}

	public function resolve(name:String, range:String):RegistryVersion {
		var candidates = packages.get(name);
		if (candidates == null)
			throw 'Registry has no package "$name"';
		var exact = isExactVersion(range), sorted = candidates.copy();
		sorted.sort((left, right) -> compareVersions(right.version, left.version));
		for (candidate in sorted)
			if (PackageCompatibility.satisfiesVersionRange(range, candidate.version) && (exact || !candidate.yanked))
				return candidate;
		throw 'Registry has no non-yanked release of "$name" matching "$range"';
	}

	public static function parse(path:String, content:String):RegistryIndex {
		var raw:Dynamic;
		try {
			raw = Json.parse(content);
		} catch (error:Dynamic) {
			throw 'Could not parse registry index $path: ${Std.string(error)}';
		}
		if (!Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$path must contain a JSON object';
		var rawPackages:Dynamic = Reflect.field(raw, "packages");
		if (!Reflect.isObject(rawPackages) || Std.isOfType(rawPackages, Array))
			throw '$path "packages" must be an object';
		var packages:Map<String, Array<RegistryVersion>> = new Map();
		for (name in Reflect.fields(rawPackages)) {
			var packageData:Dynamic = Reflect.field(rawPackages, name), rawVersions:Dynamic = Reflect.field(packageData, "versions");
			if (!Reflect.isObject(packageData) || Std.isOfType(packageData, Array) || !Std.isOfType(rawVersions, Array))
				throw '$path package "$name" requires a versions array';
			var versions:Array<RegistryVersion> = [];
			for (rawVersion in (cast rawVersions : Array<Dynamic>)) {
				if (!Reflect.isObject(rawVersion) || Std.isOfType(rawVersion, Array))
					throw '$path package "$name" contains an invalid release';
				var version = requiredString(rawVersion, "version", path),
					checksum = requiredString(rawVersion, "checksum", path),
					yankedValue:Dynamic = Reflect.field(rawVersion, "yanked"),
					yanked = yankedValue == null ? false : castBool(yankedValue),
					compatibilityRaw:Dynamic = {
						haxeon: Reflect.field(rawVersion, "haxeon"),
						targets: Reflect.field(rawVersion, "targets"),
						runtimeAbi: Reflect.field(rawVersion, "runtimeAbi")
					};
				versions.push(new RegistryVersion(version, checksum, yanked, PackageCompatibility.parse(compatibilityRaw, '$path package "$name" release "$version"')));
			}
			packages.set(name, versions);
		}
		return new RegistryIndex(packages);
	}

	/** Append a release to a local registry index without replacing existing versions. */
	public static function appendRelease(path:String, name:String, version:String, checksum:String,
		compatibility:PackageCompatibility, native:Null<NativeManifest>):Void {
		var raw:Dynamic;
		if (FileSystem.exists(path)) {
			try {
				raw = Json.parse(File.getContent(path));
			} catch (error:Dynamic) {
				throw 'Could not parse registry index $path: ${Std.string(error)}';
			}
		} else {
			raw = {version: 1, packages: {}};
		}
		var rawPackages:Dynamic = Reflect.field(raw, "packages");
		if (!Reflect.isObject(rawPackages) || Std.isOfType(rawPackages, Array))
			throw '$path "packages" must be an object';
		var packageData:Dynamic = Reflect.field(rawPackages, name);
		if (packageData == null) {
			packageData = {versions: []};
			Reflect.setField(rawPackages, name, packageData);
		}
		var rawVersions:Dynamic = Reflect.field(packageData, "versions");
		if (!Std.isOfType(rawVersions, Array))
			throw '$path package "$name" requires a versions array';
		for (existing in (cast rawVersions : Array<Dynamic>))
			if (Reflect.field(existing, "version") == version)
				throw 'Registry release "$name@$version" is already published';
		var release:Dynamic = {version: version, checksum: checksum, yanked: false};
		if (compatibility.haxeon != null)
			Reflect.setField(release, "haxeon", compatibility.haxeon);
		if (compatibility.targets.length > 0)
			Reflect.setField(release, "targets", compatibility.targets);
		if (compatibility.runtimeAbi != null)
			Reflect.setField(release, "runtimeAbi", compatibility.runtimeAbi);
		if (native != null)
			Reflect.setField(release, "native", nativeMetadata(native));
		(cast rawVersions : Array<Dynamic>).push(release);
		var names = Reflect.fields(rawPackages);
		names.sort(Reflect.compare);
		for (packageName in names) {
			var versions:Array<Dynamic> = cast Reflect.field(rawPackages, packageName).versions;
			versions.sort((left, right) -> compareVersions(cast Reflect.field(left, "version"), cast Reflect.field(right, "version")));
		}
		var directory = Path.directory(path);
		if (directory != "" && directory != "." && !FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		File.saveContent(path, Json.stringify(raw, null, "\t") + "\n");
	}

	static function nativeMetadata(native:NativeManifest):Dynamic {
		var value:Dynamic = {targets: native.supportedTargets};
		if (native.sources.length > 0)
			Reflect.setField(value, "provider", "sources");
		if (native.cmake != null)
			Reflect.setField(value, "cmake", {source: native.cmake.source, target: native.cmake.target});
		return value;
	}

	static function isExactVersion(value:String):Bool
		return !StringTools.startsWith(value, "<") && !StringTools.startsWith(value, ">") && !StringTools.startsWith(value, "^")
			&& !StringTools.startsWith(value, "~")
			&& value.indexOf(",") < 0 && value.indexOf(" ") < 0;

	static function compareVersions(left:String, right:String):Int {
		var a = versionParts(left), b = versionParts(right);
		for (index in 0...3)
			if (a[index] != b[index])
				return a[index] < b[index] ? -1 : 1;
		return 0;
	}

	static function versionParts(value:String):Array<Int> {
		var fields = value.split("."), result = [0, 0, 0];
		for (index in 0...3) {
			if (index >= fields.length)
				continue;
			var parsed = Std.parseInt(fields[index]);
			if (parsed == null)
				throw 'Invalid registry version "$value"';
			result[index] = parsed;
		}
		return result;
	}

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function castBool(value:Dynamic):Bool {
		if (!Std.isOfType(value, Bool))
			throw "Registry yanked metadata must be boolean";
		return cast value;
	}
}
