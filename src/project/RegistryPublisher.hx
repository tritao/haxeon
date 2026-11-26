package project;

import build.execution.ProcessRunner;
import compiler.core.InternalError;
import compiler.core.TextDigest;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import project.PackageManifest.PublishManifest;
import project.RegistryIndex.RegistryPackage;
import sys.FileSystem;
import sys.io.File;

/**
 * Publishes a package into a registry's directory (`index.json` and `NAME/VERSION/`): `haxeon publish` into the source cache, and
 * `haxeon dev package` into a release's haxeon registry (docs/design/SDK_LAYOUT.md). A published package is immutable and holds
 * what builds: the package's files (those Git tracks, submodules included, when it is in a repository), its `publish.vendor`
 * directories copied in, less its `publish.exclude`; and its manifest as `publishedManifest` writes it.
 */
class RegistryPublisher {
	/**
	 * Publishes the package of `manifestPath` into `registryDirectory` as `name` at `version`. `registryPackages` are the packages its
	 * path dependencies may name, by directory: each is published as a dependency on that package's minor version. Returns the
	 * release's checksum.
	 */
	public static function publish(manifestPath:String, registryDirectory:String, name:String, version:String,
			registryPackages:Map<String, RegistryPackage>):String {
		if (!isExactVersion(version))
			throw new InternalError('Registry publication requires an exact SemVer version, got "$version"');
		var absoluteManifest = Path.normalize(Path.isAbsolute(manifestPath) ? manifestPath : Path.join([
			Sys.getCwd(),
			manifestPath
		]));
		if (!FileSystem.exists(absoluteManifest))
			throw new InternalError('Project file not found: $absoluteManifest');
		var packageRoot = Path.directory(absoluteManifest),
			manifest = PackageManifest.parse(absoluteManifest, File.getContent(absoluteManifest)),
			destination = Path.join([registryDirectory, name, version]);
		if (!manifest.publish.enabled)
			throw new InternalError('Package "${manifest.packageName}" is not published: its manifest says publish = false');
		if (FileSystem.exists(destination))
			throw new InternalError('Registry release "$name@$version" is already published and immutable');
		var files = packageFiles(packageRoot, manifest.publish);
		for (relative => source in files) {
			var target = Path.join([destination, relative]);
			ensureDirectory(Path.directory(target));
			File.copy(source, target);
		}
		ensureDirectory(destination);
		var published = publishedManifest(absoluteManifest, name, version, registryPackages);
		File.saveContent(Path.join([destination, Path.withoutDirectory(absoluteManifest)]), published);
		var checksum = checksumTree(destination);
		File.saveContent(Path.join([destination, ".haxeon-checksum"]), checksum + "\n");
		RegistryIndex.appendRelease(Path.join([registryDirectory, "index.json"]), name, version, checksum,
			manifest.compatibility, manifest.native);
		return checksum;
	}

	/**
	 * The text of the manifest at `manifestPath` as its package is published under `name` at `version`: `package.name` and
	 * `package.version` set, `publish` gone (it is done), and each path dependency on one of `registryPackages` (by directory) a
	 * dependency on that package of the haxeon registry, `^MAJOR.MINOR` of its version, under its registry name. A checkout's haxeon
	 * registry resolves its packages with this manifest too, so a project resolves to the same graph either way.
	 */
	public static function publishedManifest(manifestPath:String, name:String, version:String,
			registryPackages:Map<String, RegistryPackage>):String {
		var raw = PackageManifest.decode(manifestPath, File.getContent(manifestPath)),
			root = Path.directory(manifestPath),
			packageData:Dynamic = Reflect.field(raw, "package");
		if (packageData == null) {
			packageData = {};
			Reflect.setField(raw, "package", packageData);
		}
		var packageName:String = Reflect.field(packageData, "name");
		Reflect.setField(packageData, "name", name);
		Reflect.setField(packageData, "version", version);
		Reflect.deleteField(raw, "publish");
		var dependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (dependencies != null) {
			var published:Dynamic = {}, names = Reflect.fields(dependencies);
			names.sort(Reflect.compare);
			for (dependency in names) {
				var value:Dynamic = Reflect.field(dependencies, dependency);
				switch PackageSourceCodec.parse(value, dependency, '$manifestPath dependency "$dependency"') {
					case PackageSource.Path(path) | PackageSource.Workspace(path):
						var directory = Path.normalize(Path.isAbsolute(path) ? path : Path.join([root, path]));
						if (FileSystem.exists(directory))
							directory = Path.normalize(FileSystem.fullPath(directory));
						var target = registryPackages.get(directory);
						if (target == null)
							throw new InternalError('Package "${packageName == null ? name : packageName}" cannot be published: its dependency '
								+ '"$dependency" is the directory $directory, which is not a package of the registry');
						var parts = target.version.split(".");
						var range = '^${parts[0]}.${parts.length > 1 ? parts[1] : "0"}',
							platforms:Dynamic = Reflect.field(value, "platforms");
						Reflect.setField(published, target.name, platforms == null ? range : {
							registry: PackageSourceCodec.DEFAULT_REGISTRY,
							version: range,
							platforms: platforms
						});
					case _:
						Reflect.setField(published, dependency, value);
				}
			}
			Reflect.setField(raw, "dependencies", published);
		}
		return PackageManifest.isToml(manifestPath) ? PackageManifest.toToml(raw) : Json.stringify(raw, null,
			"\t") + "\n";
	}

	/**
	 * What publishing copies, by path in the published package: the files below `root` (Git's tracked files when it is in a work
	 * tree, submodules included), each `publish.vendor` directory's below its path, less `publish.exclude`.
	 */
	static function packageFiles(root:String, publish:PublishManifest):Map<String, String> {
		var files:Map<String, String> = [];
		function add(directory:String, prefix:String) {
			for (relative in filesBelow(directory)) {
				var published = prefix == "" ? relative : prefix + "/" + relative;
				if (!excluded(published, publish.exclude))
					files.set(published, Path.join([directory, relative]));
			}
		}
		add(root, "");
		var vendored = [for (path in publish.vendor.keys()) path];
		vendored.sort(Reflect.compare);
		for (path in vendored) {
			var directory = Path.normalize(Path.join([root, publish.vendor.get(path)]));
			if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
				throw new InternalError('$root publish.vendor.$path is not a directory: $directory');
			add(directory, Path.normalize(path));
		}
		return files;
	}

	/** Whether `path` is below or at an excluded path, where a `*` segment of a pattern stands for any one segment. */
	static function excluded(path:String, exclude:Array<String>):Bool {
		var segments = path.split("/");
		for (pattern in exclude) {
			var parts = Path.removeTrailingSlashes(Path.normalize(pattern)).split("/");
			if (parts.length > segments.length)
				continue;
			var matches = true;
			for (index in 0...parts.length)
				if (parts[index] != "*" && parts[index] != segments[index]) {
					matches = false;
					break;
				}
			if (matches)
				return true;
		}
		return false;
	}

	/**
	 * The files below `directory`, relative to it. In a Git work tree: the files Git tracks, every submodule's included (one that is
	 * not checked out is an error, as its files would be missing), and the untracked files it does not ignore. Otherwise every file,
	 * less `.git`, build outputs and lockfiles.
	 */
	static function filesBelow(directory:String):Array<String> {
		var tracked = ProcessRunner.capture("git", [
			"-C",
			directory,
			"-c",
			"core.quotePath=false",
			"ls-files",
			"--recurse-submodules"
		]);
		if (tracked.status != 0) {
			var files:Array<String> = [];
			walk(directory, "", files);
			return files;
		}
		var submodules = ProcessRunner.capture("git", ["-C", directory, "submodule", "status", "--recursive", "."]);
		if (submodules.status == 0)
			for (line in submodules.output.split("\n"))
				if (StringTools.startsWith(line, "-"))
					throw new InternalError('$directory has a submodule that is not checked out (${StringTools.trim(line.substr(1))}); '
						+ 'run git submodule update --init --recursive');
		var untracked = ProcessRunner.capture("git", [
			"-C",
			directory,
			"-c",
			"core.quotePath=false",
			"ls-files",
			"--others",
			"--exclude-standard"
		]),
			files:Array<String> = [],
			seen:Map<String, Bool> = [];
		for (path in tracked.output.split("\n").concat(untracked.status == 0 ? untracked.output.split("\n") : []))
			// A tracked file deleted in the work tree, or a submodule's entry, is not a file to copy.
			if (path.length > 0 && !seen.exists(path) && FileSystem.exists(Path.join([directory, path]))
				&& !FileSystem.isDirectory(Path.join([directory, path]))) {
				seen.set(path, true);
				files.push(path);
			}
		files.sort(Reflect.compare);
		return files;
	}

	static function walk(root:String, relative:String, result:Array<String>):Void {
		var entries = FileSystem.readDirectory(relative == "" ? root : Path.join([root, relative]));
		entries.sort(Reflect.compare);
		for (entry in entries) {
			if (entry == ".git" || entry == "build" || entry == "haxeon.lock" || entry == ".haxeon-checksum")
				continue;
			var child = relative == "" ? entry : relative + "/" + entry;
			if (FileSystem.isDirectory(Path.join([root, child])))
				walk(root, child, result);
			else
				result.push(child);
		}
	}

	static function checksumTree(root:String):String {
		var fields:Array<String> = [];
		collectChecksums(root, "", fields);
		fields.sort(Reflect.compare);
		return TextDigest.sha256(fields.join("\n"));
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
		if (value.length == 0 || value.indexOf(".") < 0 || value.indexOf("<") >= 0 || value.indexOf(">") >= 0
			|| value.indexOf("^") >= 0
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
