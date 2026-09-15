package project;

import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Publishes a package into a local immutable registry cache for development and CI. */
class RegistryPublisher {
	public static function publish(manifestPath:String, registry:String, version:String, registryRoot:String):String {
		if (!isExactVersion(version))
			throw 'Registry publication requires an exact SemVer version, got "$version"';
		var absoluteManifest = Path.normalize(Path.isAbsolute(manifestPath) ? manifestPath : Path.join([Sys.getCwd(), manifestPath]));
		if (!FileSystem.exists(absoluteManifest))
			throw 'Project file not found: $absoluteManifest';
		var packageRoot = Path.directory(absoluteManifest),
			manifest = PackageManifest.parse(absoluteManifest, File.getContent(absoluteManifest)),
			registryDirectory = Path.join([registryRoot, Sha256.encode(registry)]),
			destination = Path.join([registryDirectory, manifest.packageName, version]);
		if (FileSystem.exists(destination))
			throw 'Registry release "${manifest.packageName}@$version" is already published and immutable';
		copyTree(packageRoot, destination, "");
		var checksum = checksumTree(destination);
		File.saveContent(Path.join([destination, ".haxeon-checksum"]), checksum + "\n");
		RegistryIndex.appendRelease(Path.join([registryDirectory, "index.json"]), manifest.packageName, version, checksum, manifest.compatibility,
			manifest.native);
		return checksum;
	}

	static function copyTree(source:String, destination:String, relative:String):Void {
		ensureDirectory(destination);
		var entries = FileSystem.readDirectory(source);
		entries.sort(Reflect.compare);
		for (entry in entries) {
			if (entry == ".git" || entry == "build" || entry == "haxeon.lock" || entry == ".haxeon-checksum")
				continue;
			var sourcePath = Path.join([source, entry]),
				destinationPath = Path.join([destination, entry]);
			if (FileSystem.isDirectory(sourcePath))
				copyTree(sourcePath, destinationPath, Path.join([relative, entry]));
			else {
				ensureDirectory(Path.directory(destinationPath));
				File.copy(sourcePath, destinationPath);
			}
		}
	}

	static function checksumTree(root:String):String {
		var fields:Array<String> = [];
		collectChecksums(root, "", fields);
		fields.sort(Reflect.compare);
		return Sha256.encode(fields.join("\n"));
	}

	static function collectChecksums(root:String, relative:String, result:Array<String>):Void {
		var entries = FileSystem.readDirectory(root);
		entries.sort(Reflect.compare);
		for (entry in entries) {
			if (entry == ".haxeon-checksum")
				continue;
			var path = Path.join([root, entry]),
				child = Path.join([relative, entry]);
			if (FileSystem.isDirectory(path))
				collectChecksums(path, child, result);
			else
				result.push(child + "\t" + Sha256.make(File.getBytes(path)).toHex());
		}
	}

	static function isExactVersion(value:String):Bool {
		if (value.length == 0 || value.indexOf(".") < 0 || value.indexOf("<") >= 0 || value.indexOf(">") >= 0 || value.indexOf("^") >= 0
			|| value.indexOf("~") >= 0 || value.indexOf("*") >= 0 || value.indexOf(" ") >= 0 || value.indexOf(",") >= 0)
			return false;
		for (part in value.split("."))
			if (part.length == 0 || Std.parseInt(part) == null)
				return false;
		return true;
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
