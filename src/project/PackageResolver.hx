package project;

import build.Target;
import compiler.core.InternalError;
import haxe.io.Path;
import project.FfiManifest.FfiImportManifest;
import project.FfiManifest.ResolvedFfiImport;
import project.PackageLockfile.PackageLockEntry;
import sys.FileSystem;
import sys.io.File;

/** Resolves a package graph independently of the source acquisition mechanism. */
class PackageResolver {
	final sourceAcquirer:SourceAcquirer;

	public function new(sourceAcquirer:SourceAcquirer)
		this.sourceAcquirer = sourceAcquirer;

	/**
	 * The project of the manifest at `manifestPath`, or of `program`, a root manifest made in memory (`PackageManifest.program`):
	 * then `manifestPath` only places it, in the directory that must exist, and no file is read for it. `locked` follows
	 * `lockfile`, whose graph the result must match; a registry entry whose version is gone (an upgraded SDK no longer has it)
	 * or out of the manifest's range is picked again within the range, unless `strict` (`--locked`).
	 */
	public function resolve(manifestPath:String, ?lockfile:PackageLockfile, locked:Bool = false, ?target:Target,
			?program:PackageManifest, strict:Bool = false):ResolvedProject {
		if (locked && lockfile == null)
			throw new InternalError("haxeon.lock is required for --locked resolution");
		var absoluteManifest = program != null ? Path.join([
			FileSystem.fullPath(Path.directory(manifestPath)),
			Path.withoutDirectory(manifestPath)
		]) : canonicalExistingFile(manifestPath, 'Project file not found: $manifestPath'),
			projectRoot = Path.directory(absoluteManifest),
			rootManifest = program != null ? program : PackageManifest.parse(absoluteManifest,
				File.getContent(absoluteManifest)),
			requestedTarget = target == null ? Target.parse(rootManifest.target) : target,
			visited = new Map<String, ResolvedPackage>(),
			active = new Map<String, Bool>(),
			nameToRoot = new Map<String, String>(),
			ordered:Array<ResolvedPackage> = [],
			lockEntries:Array<PackageLockEntry> = [],
			platform = requestedTarget.isWasm() ? "web" : Target.osName(requestedTarget.os),
			compatibilities:Map<String, PackageCompatibility> = [],
			repicked:Map<String, Bool> = [],
			workspaceMembers:Map<String, {
				root:String,
				path:String
			}> = new Map();
		for (workspacePath in rootManifest.workspace) {
			var workspaceRoot = resolveDirectory(projectRoot, workspacePath, "workspace member",
				rootManifest.packageName),
				workspaceManifestPath = PackageManifest.find(workspaceRoot);
			if (workspaceManifestPath == null)
				throw new InternalError('Workspace member "$workspacePath" has no ${PackageManifest.TOML_NAME} or ${PackageManifest.JSON_NAME} in $workspaceRoot');
			var workspaceManifest = PackageManifest.parse(workspaceManifestPath,
				File.getContent(workspaceManifestPath));
			if (workspaceManifest.packageName == rootManifest.packageName)
				throw new InternalError('Workspace member "$workspacePath" duplicates root package "${rootManifest.packageName}"');
			if (workspaceMembers.exists(workspaceManifest.packageName))
				throw new InternalError('Duplicate workspace package "${workspaceManifest.packageName}"');
			workspaceMembers.set(workspaceManifest.packageName, {
				root: workspaceRoot,
				path: Path.normalize(workspacePath)
			});
		}

		function resolvePackage(acquired:AcquiredSource, requestedSource:PackageSource, ?manifestOverride:String,
				?manifestValue:PackageManifest, ?prior:PackageLockEntry):ResolvedPackage {
			if (manifestValue == null)
				manifestValue = acquired.manifest;
			var resolvedRoot = Path.normalize(FileSystem.fullPath(acquired.root)),
				manifestFile = manifestOverride == null ? PackageManifest.pathIn(resolvedRoot) : manifestOverride,
				resolvedManifest = manifestValue != null ? manifestFile : canonicalExistingFile(manifestFile,
					'Project file not found: $manifestFile');
			if (active.exists(resolvedRoot))
				throw new InternalError('Package dependency cycle reaches "$resolvedRoot"');
			var existing = visited.get(resolvedRoot);
			if (existing != null)
				return existing;
			var manifest = manifestValue != null ? manifestValue : PackageManifest.parse(resolvedManifest,
				File.getContent(resolvedManifest)),
				priorRoot = nameToRoot.get(manifest.packageName);
			if (acquired.compatibility != null)
				compatibilities.set(manifest.packageName, acquired.compatibility);
			if (priorRoot != null && priorRoot != resolvedRoot)
				throw new InternalError('Duplicate package name "${manifest.packageName}" in $priorRoot and $resolvedRoot');
			nameToRoot.set(manifest.packageName, resolvedRoot);
			active.set(resolvedRoot, true);

			var sourceRoots = [
				for (sourceRoot in manifest.sourceRoots)
					resolveDirectory(resolvedRoot, sourceRoot, 'source root', manifest.packageName)
			],
				unscopedSourceRoots = [
					for (sourceRoot in manifest.unscopedSourceRoots)
						resolveDirectory(resolvedRoot, sourceRoot, 'unscoped source root', manifest.packageName)
				],
				sources = manifest.legacySources.length == 0 ? collectSources(sourceRoots) : resolveFiles(resolvedRoot,
					manifest.legacySources,
					manifest.packageName, "source"),
				nativeSources:Array<String> = [],
				includeDirs:Array<String> = [],
				nativeCMakeInputs:Array<String> = [],
				ffiInterfaces:Array<String> = [],
				ffiProjections:Array<String> = [],
				ffiImports:Array<ResolvedFfiImport> = [];
			if (manifest.native != null) {
				nativeSources = resolveFiles(resolvedRoot, manifest.native.sources, manifest.packageName,
					"native source");
				includeDirs = [
					for (includeDir in manifest.native.includeDirs)
						resolveDirectory(resolvedRoot, includeDir, "native include directory", manifest.packageName)
				];
				if (manifest.native.cmake != null) {
					resolveDirectory(resolvedRoot, manifest.native.cmake.source, "native CMake source directory",
						manifest.packageName);
					nativeCMakeInputs = [
						for (input in manifest.native.cmake.inputs)
							resolveInput(resolvedRoot, input, "native CMake input", manifest.packageName)
					];
				}
			}
			if (manifest.ffi != null) {
				var interfaces = platform == "web"
					&& manifest.ffi.wasmInterfaces.length > 0 ? manifest.ffi.wasmInterfaces : manifest.ffi.interfaces;
				ffiInterfaces = resolveFiles(resolvedRoot, interfaces, manifest.packageName,
					"FFI interface");
				ffiProjections = resolveFiles(resolvedRoot, manifest.ffi.projections, manifest.packageName,
					"FFI projection");
				for (ffiPath in manifest.ffi.imports) {
					var ffiManifestPath = resolveFiles(resolvedRoot, [ffiPath], manifest.packageName,
						"FFI manifest")[0];
					ffiImports.push(FfiImportManifest.resolve(ffiManifestPath, resolvedRoot));
				}
			}
			ffiImports.sort((left, right) -> Reflect.compare(left.config.name, right.config.name));

			var dependencyNames = [for (name in manifest.dependencies.keys()) name];
			dependencyNames.sort(Reflect.compare);
			var resolvedDependencies:Array<String> = [], lockedDependencies:Array<PackageId> = [];
			for (dependencyName in dependencyNames) {
				var dependency = manifest.dependencies.get(dependencyName);
				if (dependency == null)
					throw new InternalError('Package "${manifest.packageName}" dependency "$dependencyName" is missing source metadata');
				var lockEntry = locked ? lockfile.get(dependency.id.name) : null,
					prior = lockfile != null ? lockfile.get(dependency.id.name) : null,
					workspaceMember = workspaceMembers.get(dependency.id.name);
				if (locked && lockEntry == null)
					throw new InternalError('haxeon.lock has no entry for dependency "${dependency.id.name}"');
				var resolvedSource:PackageSource,
					acquiredDependency:AcquiredSource,
					requestedSource:PackageSource;
				if (workspaceMember != null) {
					resolvedSource = PackageSource.Workspace(workspaceMember.path);
					requestedSource = resolvedSource;
					if (locked && lockEntry != null && !PackageSourceCodec.equal(lockEntry.source, resolvedSource))
						throw new InternalError('haxeon.lock workspace source for "${dependency.id.name}" does not match the workspace');
					acquiredDependency = new AcquiredSource(workspaceMember.root, resolvedSource);
				} else {
					// The root project's [patch.REGISTRY] resolves a registry package from a directory instead, relative to the project.
					var patch = switch dependency.source {
						case PackageSource.Registry(registry, name, _):
							var patches = rootManifest.patches.get(registry);
							patches == null ? null : patches.get(name);
						case _: null;
					},
						declared = patch != null ? PackageSource.Path(patch) : dependency.source,
						owner = patch != null ? projectRoot : resolvedRoot;
					if (locked && lockEntry != null && !PackageSourceCodec.equal(lockEntry.source, declared))
						throw new InternalError('haxeon.lock source for "${dependency.id.name}" disagrees with the manifest');
					var range = switch declared {
						case PackageSource.Registry(_, _, range): range;
						case _: null;
					},
						lockedVersion = range == null || lockEntry == null ? null : switch lockEntry.resolvedSource() {
						case PackageSource.Registry(_, _, version): version;
						case _: null;
					};
					// A live package keeps only a lockfile entry in range.
					if (range != null && prior != null && prior.resolvedRevision != null
						&& !PackageCompatibility.satisfiesVersionRange(range, prior.resolvedRevision))
						prior = null;
					// A registry entry whose version left the range is picked again, as one an upgrade removed is below.
					if (lockedVersion != null && !PackageCompatibility.satisfiesVersionRange(range, lockedVersion)) {
						if (strict)
							throw new InternalError('haxeon.lock has "${dependency.id.name}" at a version outside "$range"');
						lockEntry = null;
						repicked.set(dependency.id.name, true);
					}
					resolvedSource = lockEntry == null ? declared : lockEntry.resolvedSource();
					requestedSource = declared;
					acquiredDependency = try sourceAcquirer.acquire(resolvedSource, owner,
						dependency.id) catch (missing:project.RegistryIndex.MissingRelease) {
							if (strict || lockEntry == null)
								throw missing;
							repicked.set(dependency.id.name, true);
							sourceAcquirer.acquire(declared, owner, dependency.id);
						}
				}
				var resolved = resolvePackage(acquiredDependency, requestedSource, null, null, prior);
				if (resolved.name != dependencyName)
					throw new InternalError('Package "${manifest.packageName}" declares dependency "$dependencyName" but its manifest in ${resolved.root} names package "${resolved.name}"');
				lockedDependencies.push(resolved.id);
				if (dependency.platforms.length == 0 || dependency.platforms.contains(platform))
					resolvedDependencies.push(resolved.name);
			}
			active.remove(resolvedRoot);
			var resolvedPackage = new ResolvedPackage(manifest.packageName, resolvedRoot, manifest, sourceRoots,
				unscopedSourceRoots, sources,
				resolvedDependencies, nativeSources, includeDirs, nativeCMakeInputs, ffiInterfaces, ffiProjections,
				ffiImports, acquired.source);
			visited.set(resolvedRoot, resolvedPackage);
			ordered.push(resolvedPackage);
			// A live registry package keeps the lockfile's entry as it is: its version (in range) and the checksum a release wrote.
			var kept = acquired.live && prior != null
				&& PackageSourceCodec.equal(prior.source, requestedSource) ? prior : null;
			lockEntries.push(new PackageLockEntry(manifest.packageId, requestedSource,
				kept != null ? kept.resolvedRevision : acquired.resolvedRevision,
				kept != null ? kept.checksum : acquired.checksum,
				lockedDependencies));
			return resolvedPackage;
		}

		var rootPackage = resolvePackage(new AcquiredSource(projectRoot, PackageSource.Path(".")),
			PackageSource.Path("."), absoluteManifest, program);
		var workspaceNames = [for (name in workspaceMembers.keys()) name];
		workspaceNames.sort(Reflect.compare);
		for (workspaceName in workspaceNames) {
			var member = workspaceMembers.get(workspaceName);
			if (member != null && visited.get(member.root) == null)
				resolvePackage(new AcquiredSource(member.root, PackageSource.Workspace(member.path)),
					PackageSource.Workspace(member.path));
		}
		var resolvedLockfile = new PackageLockfile(lockEntries);
		if (locked)
			lockfile.validateGraph(resolvedLockfile, repicked);
		// Keep a single lock graph across platforms, but give each build only the packages it uses.
		var all = new ResolvedPackageGraph(ordered), included:Map<String, Bool> = [];
		function include(resolved:ResolvedPackage):Void {
			if (included.exists(resolved.name))
				return;
			included.set(resolved.name, true);
			resolved.manifest.compatibility.validate(resolved.name, requestedTarget);
			var compatibility = compatibilities.get(resolved.name);
			if (compatibility != null)
				compatibility.validate(resolved.name, requestedTarget);
			for (name in resolved.dependencies)
				include(all.get(name));
		}
		include(rootPackage);
		for (name in workspaceNames)
			include(all.get(name));
		return new ResolvedProject(projectRoot, absoluteManifest, rootPackage.manifest, rootPackage,
			new ResolvedPackageGraph([for (resolved in ordered) if (included.exists(resolved.name)) resolved]),
			resolvedLockfile);
	}

	static function canonicalExistingFile(path:String, message:String):String {
		var absolute = Path.normalize(Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));
		if (!FileSystem.exists(absolute) || FileSystem.isDirectory(absolute))
			throw new InternalError(message);
		return FileSystem.fullPath(absolute);
	}

	static function resolveDirectory(root:String, relative:String, kind:String, packageName:String):String {
		var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
		if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
			throw new InternalError(MissingPath.describe('Package "$packageName" $kind', path));
		return FileSystem.fullPath(path);
	}

	static function resolveFiles(root:String, paths:Array<String>, packageName:String, kind:String):Array<String> {
		var result = [];
		for (relative in paths) {
			var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path))
				throw new InternalError(MissingPath.describe('Package "$packageName" $kind', path));
			result.push(FileSystem.fullPath(path));
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function resolveInput(root:String, relative:String, kind:String, packageName:String):String {
		var path = Path.normalize(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
		if (!FileSystem.exists(path))
			throw new InternalError(MissingPath.describe('Package "$packageName" $kind', path));
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
