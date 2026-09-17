package project;

import build.execution.ProcessRunner;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Resolves immutable registry releases from a content-addressed local cache. */
class RegistrySourceAcquirer implements SourceAcquirer {
	final cacheRoot:String;

	public function new(cacheRoot:String)
		this.cacheRoot = Path.normalize(cacheRoot);

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Registry(registry, name, range):
				var registryDirectory = Path.join([cacheRoot, Sha256.encode(registry)]),
					indexPath = Path.join([registryDirectory, "index.json"]);
				if (!FileSystem.exists(indexPath))
					throw 'Registry index for "$registry" is not in the Haxeon cache: $indexPath';
				var index = RegistryIndex.parse(indexPath, File.getContent(indexPath)),
					release = index.resolve(name, range),
					destination = Path.join([registryDirectory, name, release.version]);
				if (!FileSystem.exists(destination))
					publishArchive(registryDirectory, name, release.version, release.checksum, destination, packageId);
				else if (!FileSystem.isDirectory(destination))
					throw 'Registry cache entry for "$packageId" is not a directory: $destination';
				validateChecksum(destination, release.checksum, packageId);
				new AcquiredSource(FileSystem.fullPath(destination), PackageSource.Registry(registry, name, release.version), release.version,
					release.checksum, release.compatibility);
			case _:
				throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the registry acquirer';
		};

	function publishArchive(registryDirectory:String, name:String, version:String, checksum:String, destination:String, packageId:PackageId):Void {
		var archiveRoot = Path.join([registryDirectory, "downloads"]),
			archive = Path.join([archiveRoot, '$name-$version.zip']);
		if (!FileSystem.exists(archive))
			archive = Path.join([archiveRoot, '$name-$version.tar.gz']);
		if (!FileSystem.exists(archive))
			throw 'Registry release "$name@$version" is not in the Haxeon cache; place its archive at $archive';
		var bytes = File.getBytes(archive);
		if (Sha256.make(bytes).toHex() != checksum)
			throw 'Registry release "$packageId" failed checksum verification';
		ensureDirectory(Path.directory(destination));
		var temporary = destination + '.extract-${Std.int(Date.now().getTime())}';
		ensureDirectory(temporary);
		var command = StringTools.endsWith(archive, ".zip") ? "unzip" : "tar",
			arguments = command == "unzip" ? ["-q", archive, "-d", temporary] : ["-xzf", archive, "-C", temporary],
			status = ProcessRunner.run(command, arguments, temporary, new Map());
		if (status != 0)
			throw 'Could not extract registry release "$packageId"';
		var sourceRoot = findManifestRoot(temporary);
		if (sourceRoot == null)
			throw 'Registry release "$packageId" does not contain haxeon.json';
		FileSystem.rename(sourceRoot, destination);
		if (sourceRoot != temporary)
			FileSystem.deleteDirectory(temporary);
		File.saveContent(Path.join([destination, ".haxeon-checksum"]), checksum + "\n");
	}

	function validateChecksum(root:String, expected:String, packageId:PackageId):Void {
		var marker = Path.join([root, ".haxeon-checksum"]);
		if (!FileSystem.exists(marker) || StringTools.trim(File.getContent(marker)) != expected)
			throw 'Registry source "$packageId" failed checksum verification';
	}

	function findManifestRoot(root:String):Null<String> {
		if (FileSystem.exists(Path.join([root, "haxeon.json"])))
			return root;
		for (entry in FileSystem.readDirectory(root)) {
			var path = Path.join([root, entry]);
			if (FileSystem.isDirectory(path) && FileSystem.exists(Path.join([path, "haxeon.json"])))
				return path;
		}
		return null;
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
