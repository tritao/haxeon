package project;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import project.PackageLockfile.PackageLockEntry;
import project.FfiManifest.ResolvedFfiImport;
import project.FfiManifest.FfiImportManifest;
import build.Target;

/** Resolves a package graph independently of the source acquisition mechanism. */
class PackageResolver {
	public static inline var MANIFEST_NAME = "haxeon.json";

	final sourceAcquirer:SourceAcquirer;

	public function new(sourceAcquirer:SourceAcquirer)
		this.sourceAcquirer = sourceAcquirer;

	public function resolve(manifestPath:String, ?lockfile:PackageLockfile, locked:Bool = false, ?target:Target):ResolvedProject {
		if (locked && lockfile == null)
			throw "haxeon.lock is required for --locked resolution";
		var absoluteManifest = canonicalExistingFile(manifestPath, 'Project file not found: $manifestPath'),
			projectRoot = Path.directory(absoluteManifest),
			rootManifest = PackageManifest.parse(absoluteManifest, File.getContent(absoluteManifest)),
			requestedTarget = target == null ? Target.parse(rootManifest.target) : target,
			visited = new Map<String, ResolvedPackage>(),
			active = new Map<String, Bool>(),
			nameToRoot = new Map<String, String>(),
			ordered:Array<ResolvedPackage> = [],
			lockEntries:Array<PackageLockEntry> = [],
			workspaceMembers:Map<String, {
				root:String,
				path:String
			}> = new Map();
		for (workspacePath in rootManifest.workspace) {
			var workspaceRoot = resolveDirectory(projectRoot, workspacePath, "workspace member", rootManifest.packageName),
				workspaceManifestPath = Path.join([workspaceRoot, MANIFEST_NAME]);
			if (!FileSystem.exists(workspaceManifestPath))
				throw 'Workspace member "$workspacePath" has no $MANIFEST_NAME at $workspaceManifestPath';
			var workspaceManifest = PackageManifest.parse(workspaceManifestPath, File.getContent(workspaceManifestPath));
			if (workspaceManifest.packageName == rootManifest.packageName)
				throw 'Workspace member "$workspacePath" duplicates root package "${rootManifest.packageName}"';
			if (workspaceMembers.exists(workspaceManifest.packageName))
				throw 'Duplicate workspace package "${workspaceManifest.packageName}"';
			workspaceMembers.set(workspaceManifest.packageName, {root: workspaceRoot, path: Path.normalize(workspacePath)});
		}

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
			manifest.compatibility.validate(manifest.packageName, requestedTarget);
			if (acquired.compatibility != null)
				acquired.compatibility.validate(manifest.packageName, requestedTarget);
			if (priorRoot != null && priorRoot != resolvedRoot)
				throw 'Duplicate package name "${manifest.packageName}" in $priorRoot and $resolvedRoot';
			nameToRoot.set(manifest.packageName, resolvedRoot);
			active.set(resolvedRoot, true);

			var sourceRoots = [
				for (sourceRoot in manifest.sourceRoots)
					resolveDirectory(resolvedRoot, sourceRoot, 'source root', manifest.packageName)
			],
				sources = manifest.legacySources.length == 0 ? collectSources(sourceRoots) : resolveFiles(resolvedRoot, manifest.legacySources,
				manifest.packageName, "source"),
				nativeSources:Array<String> = [], includeDirs:Array<String> = [], nativeCMakeInputs:Array<String> = [], ffiInterfaces:Array<String> = [],
				ffiProjections:Array<String> = [], ffiImports:Array<ResolvedFfiImport> = [];
			if (manifest.native != null) {
				nativeSources = resolveFiles(resolvedRoot, manifest.native.sources, manifest.packageName, "native source");
				includeDirs = [
					for (includeDir in manifest.native.includeDirs)
						resolveDirectory(resolvedRoot, includeDir, "native include directory", manifest.packageName)
				];
				if (manifest.native.cmake != null) {
					resolveDirectory(resolvedRoot, manifest.native.cmake.source, "native CMake source directory", manifest.packageName);
					nativeCMakeInputs = [
						for (input in manifest.native.cmake.inputs)
							resolveInput(resolvedRoot, input, "native CMake input", manifest.packageName)
					];
				}
			}
			if (manifest.ffi != null) {
				ffiInterfaces = resolveFiles(resolvedRoot, manifest.ffi.interfaces, manifest.packageName, "FFI interface");
				ffiProjections = resolveFiles(resolvedRoot, manifest.ffi.projections, manifest.packageName, "FFI projection");
				for (ffiPath in manifest.ffi.imports) {
					var ffiManifestPath = resolveFiles(resolvedRoot, [ffiPath], manifest.packageName, "FFI manifest")[0];
					ffiImports.push(FfiImportManifest.resolve(ffiManifestPath, resolvedRoot));
				}
			}
			ffiImports.sort((left, right) -> Reflect.compare(left.config.name, right.config.name));

			var dependencyNames = [for (name in manifest.dependencies.keys()) name];
			dependencyNames.sort(Reflect.compare);
			var resolvedDependencies:Array<String> = [];
			for (dependencyName in dependencyNames) {
				var dependency = manifest.dependencies.get(dependencyName);
				if (dependency == null)
					throw 'Package "${manifest.packageName}" dependency "$dependencyName" is missing source metadata';
				var lockEntry = locked ? lockfile.get(dependency.id.name) : null,
					workspaceMember = workspaceMembers.get(dependency.id.name);
				if (locked && lockEntry == null)
					throw 'haxeon.lock has no entry for dependency "${dependency.id.name}"';
				var resolvedSource:PackageSource,
					acquiredDependency:AcquiredSource,
					requestedSource:PackageSource;
				if (workspaceMember != null) {
					resolvedSource = PackageSource.Workspace(workspaceMember.path);
					requestedSource = resolvedSource;
					if (locked && !PackageSourceCodec.equal(lockEntry.source, resolvedSource))
						throw 'haxeon.lock workspace source for "${dependency.id.name}" does not match the workspace';
					acquiredDependency = new AcquiredSource(workspaceMember.root, resolvedSource);
				} else {
					if (locked && !PackageSourceCodec.equal(lockEntry.source, dependency.source))
						throw 'haxeon.lock source for "${dependency.id.name}" disagrees with the manifest';
					resolvedSource = lockEntry == null ? dependency.source : lockEntry.resolvedSource();
					requestedSource = dependency.source;
					acquiredDependency = sourceAcquirer.acquire(resolvedSource, resolvedRoot, dependency.id);
				}
				var resolved = resolvePackage(acquiredDependency, requestedSource);
				if (resolved.name != dependencyName)
					throw 'Package "${manifest.packageName}" declares dependency "$dependencyName" but ${resolved.root}/$MANIFEST_NAME names package "${resolved.name}"';
				resolvedDependencies.push(resolved.name);
			}
			active.remove(resolvedRoot);
			var resolvedPackage = new ResolvedPackage(manifest.packageName, resolvedRoot, manifest, sourceRoots, sources, resolvedDependencies, nativeSources,
				includeDirs, nativeCMakeInputs, ffiInterfaces, ffiProjections, ffiImports, acquired.source);
			visited.set(resolvedRoot, resolvedPackage);
			ordered.push(resolvedPackage);
			lockEntries.push(new PackageLockEntry(manifest.packageId, requestedSource, acquired.resolvedRevision, acquired.checksum,
				[for (dependencyName in resolvedDependencies) new PackageId(dependencyName)]));
			return resolvedPackage;
		}

		var rootPackage = resolvePackage(new AcquiredSource(projectRoot, PackageSource.Path(".")), PackageSource.Path("."));
		var workspaceNames = [for (name in workspaceMembers.keys()) name];
		workspaceNames.sort(Reflect.compare);
		for (workspaceName in workspaceNames) {
			var member = workspaceMembers.get(workspaceName);
			if (member != null && visited.get(member.root) == null)
				resolvePackage(new AcquiredSource(member.root, PackageSource.Workspace(member.path)), PackageSource.Workspace(member.path));
		}
		var resolvedLockfile = new PackageLockfile(lockEntries);
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

	static function resolveInput(root:String, relative:String, kind:String, packageName:String):String {
		var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
		if (!FileSystem.exists(path))
			throw 'Package "$packageName" $kind does not exist: $path';
		return FileSystem.fullPath(path);
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
