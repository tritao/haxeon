package project;

import build.execution.ProcessRunner;
import compiler.core.InternalError;
import compiler.core.TextDigest;
import haxe.crypto.Sha256;
import haxe.io.Path;
import project.RegistryIndex.MissingRelease;
import sys.FileSystem;
import sys.io.File;

/**
 * Resolves registry releases: immutable ones, unpacked below their registry's index and checked against its checksum, and live
 * ones, which a checkout's haxeon registry resolves from the package's own directory (docs/design/SDK_LAYOUT.md). A registry's
 * directory is in the content-addressed source cache, except the `haxeon` registry's packages that the SDK's registry has.
 */
class RegistrySourceAcquirer implements SourceAcquirer {
	final cacheRoot:String;
	final sdkRegistry:Null<String>;

	/** `sdkRegistry` is the SDK's registry directory (`build.HaxeonSdk.registryRoot`), consulted first for the `haxeon` registry. */
	public function new(cacheRoot:String, ?sdkRegistry:String) {
		this.cacheRoot = Path.normalize(cacheRoot);
		this.sdkRegistry = sdkRegistry;
	}

	/** The directory of `registry` that holds `name`: the SDK's for the haxeon registry when its index has the package. */
	public function directory(registry:String, name:String):String {
		if (registry == PackageSourceCodec.DEFAULT_REGISTRY && sdkRegistry != null) {
			var index = RegistryIndex.load(sdkRegistry);
			if (index != null && index.packages.exists(name))
				return sdkRegistry;
		}
		return Path.join([cacheRoot, TextDigest.sha256(registry)]);
	}

	/** The index of `registry` that `name` resolves from. */
	public function index(registry:String, name:String):RegistryIndex {
		var registryDirectory = directory(registry, name), index = RegistryIndex.load(registryDirectory);
		if (index == null)
			throw new compiler.core
				.UsageError('The "$registry" registry is not available: no index at ${Path.join([registryDirectory, "index.json"])}');
		return index;
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Registry(registry, name, range):
				var registryDirectory = directory(registry, name),
					index = RegistryIndex.load(registryDirectory);
				if (index == null)
					throw new InternalError('Registry index for "$registry" is not in the Haxeon cache: ${Path.join([registryDirectory, "index.json"])}');
				var live = index.live(name);
				if (live != null)
					return acquireLive(registry, name, range, live, index);
				var release = index.resolve(name, range),
					destination = Path.join([registryDirectory, name, release.version]);
				if (!FileSystem.exists(destination))
					publishArchive(registryDirectory, name, release.version, release.checksum, destination, packageId);
				else if (!FileSystem.isDirectory(destination))
					throw new InternalError('Registry cache entry for "$packageId" is not a directory: $destination');
				validateChecksum(destination, release.checksum, packageId);
				new AcquiredSource(FileSystem.fullPath(destination),
					PackageSource.Registry(registry, name, release.version), release.version,
					release.checksum, release.compatibility);
			case _:
				throw new InternalError('Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the registry acquirer');
		};

	/**
	 * A live package: its directory, with its manifest as publishing writes it (`RegistryPublisher.publishedManifest`). A range must
	 * hold the package's version; an exact version, a lockfile's, is taken as it is, so the lockfile's entry stays the same whichever
	 * SDK resolves it.
	 */
	function acquireLive(registry:String, name:String, range:String, live:RegistryIndex.RegistryVersion,
			index:RegistryIndex):AcquiredSource {
		var exact = RegistryIndex.isExactVersion(range);
		if (!exact && !PackageCompatibility.satisfiesVersionRange(range, live.version))
			throw new MissingRelease('Registry has no release of "$name" matching "$range" (this Haxeon\'s is ${live.version})');
		var manifestPath = PackageManifest.find(live.path);
		if (manifestPath == null)
			throw new InternalError('Registry package "$name" has no ${PackageManifest.TOML_NAME} or ${PackageManifest.JSON_NAME} in ${live.path}');
		var version = exact ? range : live.version,
			manifest = PackageManifest.parse(manifestPath,
				RegistryPublisher.publishedManifest(manifestPath, name, live.version, index.liveDirectories()));
		return new AcquiredSource(live.path, PackageSource.Registry(registry, name, version), version, null,
			live.compatibility, manifest, true);
	}

	function publishArchive(registryDirectory:String, name:String, version:String, checksum:String, destination:String,
			packageId:PackageId):Void {
		var archiveRoot = Path.join([registryDirectory, "downloads"]),
			archive = Path.join([archiveRoot, '$name-$version.zip']);
		if (!FileSystem.exists(archive))
			archive = Path.join([archiveRoot, '$name-$version.tar.gz']);
		if (!FileSystem.exists(archive))
			throw new InternalError('Registry release "$name@$version" is not in the Haxeon cache; place its archive at $archive');
		var bytes = File.getBytes(archive);
		if (Sha256.make(bytes).toHex() != checksum)
			throw new InternalError('Registry release "$packageId" failed checksum verification');
		ensureDirectory(Path.directory(destination));
		var temporary = destination + '.extract-${Std.int(Date.now().getTime())}';
		ensureDirectory(temporary);
		var command = StringTools.endsWith(archive, ".zip") ? "unzip" : "tar",
			arguments = command == "unzip" ? ["-q", archive, "-d", temporary] : ["-xzf", archive, "-C", temporary],
			status = ProcessRunner.run(command, arguments, temporary, new Map());
		if (status != 0)
			throw new InternalError('Could not extract registry release "$packageId"');
		var sourceRoot = findManifestRoot(temporary);
		if (sourceRoot == null)
			throw new InternalError('Registry release "$packageId" does not contain ${PackageManifest.TOML_NAME} or ${PackageManifest.JSON_NAME}');
		FileSystem.rename(sourceRoot, destination);
		if (sourceRoot != temporary)
			FileSystem.deleteDirectory(temporary);
		File.saveContent(Path.join([destination, ".haxeon-checksum"]), checksum + "\n");
	}

	function validateChecksum(root:String, expected:String, packageId:PackageId):Void {
		var marker = Path.join([root, ".haxeon-checksum"]);
		if (!FileSystem.exists(marker) || StringTools.trim(File.getContent(marker)) != expected)
			throw new InternalError('Registry source "$packageId" failed checksum verification');
	}

	function findManifestRoot(root:String):Null<String> {
		if (PackageManifest.find(root) != null)
			return root;
		for (entry in FileSystem.readDirectory(root)) {
			var path = Path.join([root, entry]);
			if (FileSystem.isDirectory(path) && PackageManifest.find(path) != null)
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
