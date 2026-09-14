package project;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Reads manifests and resolves only local path dependencies. */
class ProjectDiscovery {
	public static inline var MANIFEST_NAME = "haxeon.json";

	public static function discover(manifestPath:String):ResolvedProject {
		var absoluteManifest = canonicalExistingFile(manifestPath, 'Project file not found: $manifestPath'),
			projectRoot = Path.directory(absoluteManifest),
			visited = new Map<String, ResolvedPackage>(),
			active = new Map<String, Bool>(),
			nameToRoot = new Map<String, String>(),
			ordered:Array<ResolvedPackage> = [];

		function resolve(path:String):ResolvedPackage {
			var resolvedManifest = canonicalExistingFile(path, 'Project file not found: $path'),
				root = Path.directory(resolvedManifest);
			if (active.exists(root))
				throw 'Local package dependency cycle reaches "$root"';
			var existing = visited.get(root);
			if (existing != null)
				return existing;
			var manifest = ProjectManifest.parse(resolvedManifest, File.getContent(resolvedManifest)),
				priorRoot = nameToRoot.get(manifest.packageName);
			if (priorRoot != null && priorRoot != root)
				throw 'Duplicate package name "${manifest.packageName}" in $priorRoot and $root';
			nameToRoot.set(manifest.packageName, root);
			active.set(root, true);

			var sourceRoots = [
				for (sourceRoot in manifest.sourceRoots)
					resolveDirectory(root, sourceRoot, 'source root', manifest.packageName)
			], sources = manifest.legacySources.length == 0 ? collectSources(sourceRoots) : resolveFiles(root, manifest.legacySources, manifest.packageName,
				"source"),
				nativeSources:Array<String> = [], includeDirs:Array<String> = [];
			if (manifest.native != null) {
				nativeSources = resolveFiles(root, manifest.native.sources, manifest.packageName, "native source");
				includeDirs = [
					for (includeDir in manifest.native.includeDirs)
						resolveDirectory(root, includeDir, "native include directory", manifest.packageName)
				];
			}

			var dependencyNames = [for (name in manifest.dependencies.keys()) name];
			dependencyNames.sort(Reflect.compare);
			var resolvedDependencies:Array<String> = [];
			for (dependencyName in dependencyNames) {
				var dependencyPath = Path.normalize(Path.join([root, manifest.dependencies.get(dependencyName)]));
				if (!FileSystem.exists(dependencyPath) || !FileSystem.isDirectory(dependencyPath))
					throw 'Package "${manifest.packageName}" dependency "$dependencyName" path does not exist: $dependencyPath';
				var dependencyRoot = FileSystem.fullPath(dependencyPath),
					dependencyManifest = Path.join([dependencyRoot, MANIFEST_NAME]);
				if (!FileSystem.exists(dependencyManifest))
					throw 'Package "${manifest.packageName}" dependency "$dependencyName" has no $MANIFEST_NAME at $dependencyManifest';
				var resolved = resolve(dependencyManifest);
				if (resolved.name != dependencyName)
					throw 'Package "${manifest.packageName}" declares dependency "$dependencyName" but $dependencyManifest names package "${resolved.name}"';
				resolvedDependencies.push(resolved.name);
			}
			active.remove(root);
			var resolvedPackage = new ResolvedPackage(manifest.packageName, root, manifest, sourceRoots, sources, resolvedDependencies, nativeSources,
				includeDirs);
			visited.set(root, resolvedPackage);
			ordered.push(resolvedPackage);
			return resolvedPackage;
		}

		var rootPackage = resolve(absoluteManifest);
		return new ResolvedProject(projectRoot, absoluteManifest, rootPackage.manifest, rootPackage, new ResolvedPackageGraph(ordered));
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
