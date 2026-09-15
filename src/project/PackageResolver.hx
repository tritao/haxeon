package project;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import project.PackageLockfile.PackageLockEntry;

/** Resolves a package graph independently of the source acquisition mechanism. */
class PackageResolver {
	public static inline var MANIFEST_NAME = "haxeon.json";

	final sourceAcquirer:SourceAcquirer;

	public function new(sourceAcquirer:SourceAcquirer)
		this.sourceAcquirer = sourceAcquirer;

	public function resolve(manifestPath:String, ?lockfile:PackageLockfile, locked:Bool = false):ResolvedProject {
		if (locked && lockfile == null)
			throw "haxeon.lock is required for --locked resolution";
		var absoluteManifest = canonicalExistingFile(manifestPath, 'Project file not found: $manifestPath'),
			projectRoot = Path.directory(absoluteManifest),
			visited = new Map<String, ResolvedPackage>(),
			active = new Map<String, Bool>(),
			nameToRoot = new Map<String, String>(),
			ordered:Array<ResolvedPackage> = [],
			lockEntries:Array<PackageLockEntry> = [];

		function resolvePackage(acquired:AcquiredSource, requestedSource:PackageSource):ResolvedPackage {
			var resolvedRoot = Path.normalize(FileSystem.fullPath(acquired.root)),
				resolvedManifest = canonicalExistingFile(Path.join([resolvedRoot, MANIFEST_NAME]),
					'Project file not found: ${Path.join([resolvedRoot, MANIFEST_NAME])}');
			if (active.exists(resolvedRoot))
				throw 'Package dependency cycle reaches "$resolvedRoot"';
			var existing = visited.get(resolvedRoot);
			if (existing != null)
				return existing;
			var manifest = PackageManifest.parse(resolvedManifest, File.getContent(resolvedManifest)),
				priorRoot = nameToRoot.get(manifest.packageName);
			if (priorRoot != null && priorRoot != resolvedRoot)
				throw 'Duplicate package name "${manifest.packageName}" in $priorRoot and $resolvedRoot';
			nameToRoot.set(manifest.packageName, resolvedRoot);
			active.set(resolvedRoot, true);

			var sourceRoots = [
				for (sourceRoot in manifest.sourceRoots)
					resolveDirectory(resolvedRoot, sourceRoot, 'source root', manifest.packageName)
			], sources = manifest.legacySources.length == 0 ? collectSources(sourceRoots) : resolveFiles(resolvedRoot, manifest.legacySources,
				manifest.packageName, "source"), nativeSources:Array<String> = [], includeDirs:Array<String> = [];
			if (manifest.native != null) {
				nativeSources = resolveFiles(resolvedRoot, manifest.native.sources, manifest.packageName, "native source");
				includeDirs = [
					for (includeDir in manifest.native.includeDirs)
						resolveDirectory(resolvedRoot, includeDir, "native include directory", manifest.packageName)
				];
			}

			var dependencyNames = [for (name in manifest.dependencies.keys()) name];
			dependencyNames.sort(Reflect.compare);
			var resolvedDependencies:Array<String> = [];
			for (dependencyName in dependencyNames) {
				var dependency = manifest.dependencies.get(dependencyName);
				if (dependency == null)
					throw 'Package "${manifest.packageName}" dependency "$dependencyName" is missing source metadata';
				var lockEntry = locked ? lockfile.get(dependency.id.name) : null;
				if (locked && lockEntry == null)
					throw 'haxeon.lock has no entry for dependency "${dependency.id.name}"';
				if (locked && !PackageSourceCodec.equal(lockEntry.source, dependency.source))
					throw 'haxeon.lock source for "${dependency.id.name}" disagrees with the manifest';
				var source = lockEntry == null ? dependency.source : lockEntry.resolvedSource(),
					acquiredDependency = sourceAcquirer.acquire(source, resolvedRoot, dependency.id),
					resolved = resolvePackage(acquiredDependency, dependency.source);
				if (resolved.name != dependencyName)
					throw 'Package "${manifest.packageName}" declares dependency "$dependencyName" but ${resolved.root}/$MANIFEST_NAME names package "${resolved.name}"';
				resolvedDependencies.push(resolved.name);
			}
			active.remove(resolvedRoot);
			var resolvedPackage = new ResolvedPackage(manifest.packageName, resolvedRoot, manifest, sourceRoots, sources, resolvedDependencies, nativeSources,
				includeDirs, acquired.source);
			visited.set(resolvedRoot, resolvedPackage);
			ordered.push(resolvedPackage);
			lockEntries.push(new PackageLockEntry(manifest.packageId, requestedSource, acquired.resolvedRevision, null,
				[for (dependencyName in resolvedDependencies) new PackageId(dependencyName)]));
			return resolvedPackage;
		}

		var rootPackage = resolvePackage(new AcquiredSource(projectRoot, PackageSource.Path(".")), PackageSource.Path(".")),
			resolvedLockfile = new PackageLockfile(lockEntries);
		if (locked)
			lockfile.validateGraph(resolvedLockfile);
		return new ResolvedProject(projectRoot, absoluteManifest, rootPackage.manifest, rootPackage, new ResolvedPackageGraph(ordered), resolvedLockfile);
	}

	static function canonicalExistingFile(path:String, message:String):String {
		var absolute = Path.normalize(Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));
		if (!FileSystem.exists(absolute) || FileSystem.isDirectory(absolute))
			throw message;
		return FileSystem.fullPath(absolute);
	}

	static function resolveDirectory(root:String, relative:String, kind:String, packageName:String):String {
		var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
		if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
			throw 'Package "$packageName" $kind does not exist: $path';
		return FileSystem.fullPath(path);
	}

	static function resolveFiles(root:String, paths:Array<String>, packageName:String, kind:String):Array<String> {
		var result = [];
		for (relative in paths) {
			var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path))
				throw 'Package "$packageName" $kind does not exist: $path';
			result.push(FileSystem.fullPath(path));
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function collectSources(sourceRoots:Array<String>):Array<String> {
		var result:Array<String> = [];
		for (sourceRoot in sourceRoots)
			collect(sourceRoot, result);
		result.sort(Reflect.compare);
		return result;
	}

	static function collect(directory:String, result:Array<String>):Void {
		var entries = FileSystem.readDirectory(directory);
		entries.sort(Reflect.compare);
		for (entry in entries) {
			var path = Path.join([directory, entry]);
			if (FileSystem.isDirectory(path))
				collect(path, result);
			else if (StringTools.endsWith(entry, ".hx"))
				result.push(FileSystem.fullPath(path));
		}
	}
}
