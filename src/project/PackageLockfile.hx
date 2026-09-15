package project;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

class PackageLockEntry {
	public final id:PackageId;
	public final source:PackageSource;
	public final resolvedRevision:Null<String>;
	public final checksum:Null<String>;
	public final dependencies:Array<PackageId>;

	public function new(id:PackageId, source:PackageSource, ?resolvedRevision:String, ?checksum:String, ?dependencies:Array<PackageId>) {
		this.id = id;
		this.source = source;
		this.resolvedRevision = resolvedRevision;
		this.checksum = checksum;
		this.dependencies = dependencies == null ? [] : dependencies.copy();
		this.dependencies.sort((left, right) -> Reflect.compare(left.name, right.name));
	}

	public function resolvedSource():PackageSource
		return switch source {
			case PackageSource.Git(url, _):
				if (resolvedRevision == null || resolvedRevision.length == 0)
					throw 'Lockfile entry "${id.name}" is missing its resolved Git revision';
				PackageSource.Git(url, resolvedRevision);
			case PackageSource.Registry(registry, name, _):
				if (resolvedRevision == null || resolvedRevision.length == 0)
					throw 'Lockfile entry "${id.name}" is missing its resolved registry version';
				PackageSource.Registry(registry, name, resolvedRevision);
			case _: source;
		};
}

/** Deterministic exact package graph stored in haxeon.lock. */
class PackageLockfile {
	public static inline var VERSION = 1;
	public final entries:Array<PackageLockEntry>;

	final byName:Map<String, PackageLockEntry>;

	public function new(entries:Array<PackageLockEntry>) {
		this.entries = entries.copy();
		this.entries.sort((left, right) -> Reflect.compare(left.id.name, right.id.name));
		byName = new Map();
		for (entry in this.entries) {
			if (byName.exists(entry.id.name))
				throw 'Duplicate package in lockfile: ${entry.id.name}';
			byName.set(entry.id.name, entry);
		}
	}

	public function get(name:String):Null<PackageLockEntry>
		return byName.get(name);

	public function validateGraph(actual:PackageLockfile):Void {
		if (entries.length != actual.entries.length)
			throw "haxeon.lock does not describe the resolved package graph";
		for (expected in entries) {
			var resolved = actual.get(expected.id.name);
			if (resolved == null
				|| !PackageSourceCodec.equal(expected.source, resolved.source)
				|| expected.resolvedRevision != resolved.resolvedRevision
				|| expected.checksum != resolved.checksum
				|| !sameDependencies(expected.dependencies, resolved.dependencies))
				throw 'haxeon.lock entry for "${expected.id.name}" does not match the resolved package graph';
		}
	}

	public function toJson():String {
		var packages:Array<Dynamic> = [];
		for (entry in entries) {
			var value:Dynamic = {
				name: entry.id.name,
				source: PackageSourceCodec.encode(entry.source),
				dependencies: [for (dependency in entry.dependencies) dependency.name]
			};
			if (entry.resolvedRevision != null)
				Reflect.setField(value, "resolvedRevision", entry.resolvedRevision);
			if (entry.checksum != null)
				Reflect.setField(value, "checksum", entry.checksum);
			packages.push(value);
		}
		return Json.stringify({version: VERSION, packages: packages}, null, "\t") + "\n";
	}

	public function save(path:String):Void {
		var directory = haxe.io.Path.directory(path);
		if (directory != "" && directory != "." && !FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		File.saveContent(path, toJson());
	}

	public static function parse(path:String, content:String):PackageLockfile {
		var raw:Dynamic;
		try {
			raw = Json.parse(content);
		} catch (error:Dynamic) {
			throw 'Could not parse $path: ${Std.string(error)}';
		}
		if (raw == null || !Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$path must contain a JSON object';
		var version:Dynamic = Reflect.field(raw, "version");
		if (version == null || Std.int(version) != VERSION)
			throw '$path has unsupported lockfile version "$version"';
		var packages:Dynamic = Reflect.field(raw, "packages");
		if (!Std.isOfType(packages, Array))
			throw '$path "packages" must be an array';
		var entries:Array<PackageLockEntry> = [];
		for (rawPackage in (cast packages : Array<Dynamic>)) {
			if (rawPackage == null || !Reflect.isObject(rawPackage) || Std.isOfType(rawPackage, Array))
				throw '$path contains an invalid package entry';
			var name = requiredString(rawPackage, "name", path),
				source = PackageSourceCodec.parse(Reflect.field(rawPackage, "source"), name, '$path package "$name"'),
				resolvedRevision = optionalString(rawPackage, "resolvedRevision"),
				checksum = optionalString(rawPackage, "checksum"),
				dependencies = stringArray(rawPackage, "dependencies", path);
			entries.push(new PackageLockEntry(new PackageId(name), source, resolvedRevision, checksum,
				[for (dependency in dependencies) new PackageId(dependency)]));
		}
		return new PackageLockfile(entries);
	}

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function optionalString(raw:Dynamic, field:String):Null<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return null;
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw 'Lockfile field "$field" must be a non-empty string';
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return [];
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (cast item : String).length == 0)
				throw '$path "$field" must contain only non-empty strings';
			result.push(cast item);
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function sameDependencies(left:Array<PackageId>, right:Array<PackageId>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index].name != right[index].name)
				return false;
		return true;
	}
}
