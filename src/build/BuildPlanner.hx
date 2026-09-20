package build;

import build.Artifact.ArtifactKind.NativeRuntime;
import build.Artifact.ArtifactKind.Diagnostics;
import build.Artifact.ArtifactKind.Executable;
import build.Artifact.ArtifactKind.HashLinkModule;
import build.Artifact.ArtifactKind.NativeObject;
import build.Artifact.ArtifactKind.NativeSharedLibrary;
import build.Artifact.ArtifactKind.FfiNativeSharedLibrary;
import build.Artifact.ArtifactKind.FfiInterface;
import build.Artifact.ArtifactKind.NativeStaticLibrary;
import build.Artifact.ArtifactKind.WasmModule;
import build.NativeArtifactDemand.NativeArtifactDemand;
import project.ResolvedPackage;
import project.ResolvedProject;

/** Pure entry points for producing the first logical build graphs. */
class BuildPlanner {
	public static function nativeRuntime(environment:BuildEnvironment, ?variant:String):BuildPlan {
		var id = new ArtifactId("haxeon", NativeRuntime, environment.target, variant == null ? Std.string(environment.profile) : variant);
		return new BuildPlan([id], [new Artifact(id)]);
	}

	public static function module(packageId:String, target:Target, kind:Artifact.ArtifactKind, ?dependencies:Array<ArtifactId>):BuildPlan {
		var id = new ArtifactId(packageId, kind, target);
		return new BuildPlan([id], [new Artifact(id, dependencies)]);
	}

	public static function project(project:ResolvedProject, intent:BuildIntent, target:Target, nativeDemand:NativeArtifactDemand):BuildPlan {
		NativeTargetSupport.validate(project, target);
		var artifacts:Array<Artifact> = [],
			nativeShared = new Map<String, ArtifactId>(),
			nativeStatic = new Map<String, ArtifactId>(),
			ffiArtifacts:Array<ArtifactId> = [],
			ffiNativeLibraries:Array<ArtifactId> = [];
		for (resolvedPackage in project.packages.packages)
			for (ffi in resolvedPackage.ffiImports) {
				var ffiId = new ArtifactId(resolvedPackage.name, FfiInterface, target, ffi.config.name);
				artifacts.push(new Artifact(ffiId, [], [
					"manifest" => relativePath(resolvedPackage.root, ffi.manifestPath),
					"name" => ffi.config.name
				]));
				ffiArtifacts.push(ffiId);
			}
		for (resolvedPackage in project.packages.packages) {
			var thunkImports = [for (ffi in resolvedPackage.ffiImports) if (ffi.config.cxxThunks) ffi];
			if (resolvedPackage.nativeSources.length == 0 && resolvedPackage.manifest.native == null && thunkImports.length == 0)
				continue;
			var objects:Array<ArtifactId> = [],
				baseObjects:Array<ArtifactId> = [],
				thunkObjects:Map<String, ArtifactId> = [];
			if (NativeArtifactDemands.includes(nativeDemand, NativeStaticLibrary)
				|| NativeArtifactDemands.includes(nativeDemand, NativeSharedLibrary))
				for (source in resolvedPackage.nativeSources) {
					var relative = relativePath(resolvedPackage.root, source),
						id = new ArtifactId(resolvedPackage.name, NativeObject, target, relative),
						details:Map<String, String> = ["source" => relative];
					artifacts.push(new Artifact(id, [], details));
					baseObjects.push(id);
					objects.push(id);
				}
			for (ffi in thunkImports) {
				var source = 'ffi/${ffi.config.name}/${ffi.config.name}-thunks.cpp',
					id = new ArtifactId(resolvedPackage.name, NativeObject, target, 'ffi:${ffi.config.name}'),
					ffiId = new ArtifactId(resolvedPackage.name, FfiInterface, target, ffi.config.name),
					details:Map<String, String> = [
						"source" => source,
						"ffi" => ffi.config.name,
						"language" => "c++",
						"standard" => ffi.config.standard
					];
				artifacts.push(new Artifact(id, [ffiId], details));
				thunkObjects.set(ffi.config.name, id);
				objects.push(id);
			}
			if (NativeArtifactDemands.includes(nativeDemand, FfiNativeSharedLibrary))
				for (ffi in thunkImports) {
					var thunkObject = thunkObjects.get(ffi.config.name);
					if (thunkObject == null)
						throw 'Missing generated thunk object for FFI import ${ffi.config.name}';
					var ffiLibraryId = new ArtifactId(resolvedPackage.name, FfiNativeSharedLibrary, target, ffi.config.name),
						ffiDependencies = baseObjects.concat([thunkObject]);
					if (resolvedPackage.manifest.native != null && resolvedPackage.manifest.native.cmake != null)
						ffiDependencies.push(new ArtifactId(resolvedPackage.name, NativeSharedLibrary, target));
					artifacts.push(new Artifact(ffiLibraryId, ffiDependencies, ["library" => resolvedPackage.name, "ffi" => ffi.config.name]));
					ffiNativeLibraries.push(ffiLibraryId);
				}
			if (resolvedPackage.nativeSources.length > 0 && NativeArtifactDemands.includes(nativeDemand, NativeStaticLibrary)) {
				var staticId = new ArtifactId(resolvedPackage.name, NativeStaticLibrary, target);
				nativeStatic.set(resolvedPackage.name, staticId);
				artifacts.push(new Artifact(staticId, objects, ["library" => resolvedPackage.name]));
			}
			if (NativeArtifactDemands.includes(nativeDemand, NativeSharedLibrary)) {
				var sharedId = new ArtifactId(resolvedPackage.name, NativeSharedLibrary, target);
				nativeShared.set(resolvedPackage.name, sharedId);
				var sharedDetails:Map<String, String> = ["library" => resolvedPackage.name];
				if (resolvedPackage.manifest.native != null && resolvedPackage.manifest.native.cmake != null) {
					sharedDetails.set("cmake.source", resolvedPackage.manifest.native.cmake.source);
					sharedDetails.set("cmake.target", resolvedPackage.manifest.native.cmake.target);
				}
				artifacts.push(new Artifact(sharedId, objects, sharedDetails));
			}
		}

		var libraryRequirements:Array<ArtifactId> = [];
		for (resolvedPackage in project.packages.packages) {
			var shared = nativeShared.get(resolvedPackage.name),
				statik = nativeStatic.get(resolvedPackage.name);
			if (shared != null)
				libraryRequirements.push(shared);
			if (statik != null)
				libraryRequirements.push(statik);
		}
		libraryRequirements = libraryRequirements.concat(ffiNativeLibraries);
		var kind = switch target {
			case _: project.manifest.target == "wasm32" ? WasmModule : HashLinkModule;
		};
		if (intent == Check)
			kind = Diagnostics;
		var moduleId = new ArtifactId(project.rootPackage.name, kind, target);
		artifacts.push(new Artifact(moduleId, libraryRequirements.concat(ffiArtifacts),
			["entry" => project.manifest.entry == null ? "" : project.manifest.entry]));
		return new BuildPlan([moduleId], artifacts);
	}

	/** Native-only request used by package consumers such as Android packaging. */
	public static function nativePackages(project:ResolvedProject, target:Target, nativeDemand:NativeArtifactDemand):BuildPlan {
		var full = BuildPlanner.project(project, BuildIntent.Build, target, nativeDemand),
			artifacts:Array<Artifact> = [
				for (artifact in full.artifacts)
					if (artifact.id.kind == NativeObject
						|| artifact.id.kind == NativeStaticLibrary
						|| artifact.id.kind == NativeSharedLibrary
						|| artifact.id.kind == FfiNativeSharedLibrary) artifact
			],
			requested:Array<ArtifactId> = [
				for (artifact in artifacts)
					if (artifact.id.kind == NativeStaticLibrary
						|| artifact.id.kind == NativeSharedLibrary
						|| artifact.id.kind == FfiNativeSharedLibrary) artifact.id
			];
		return new BuildPlan(requested, artifacts);
	}

	static function relativePath(root:String, path:String):String {
		var normalizedRoot = haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(root)),
			normalizedPath = haxe.io.Path.normalize(path);
		if (StringTools.startsWith(normalizedPath, normalizedRoot))
			return normalizedPath.substr(normalizedRoot.length);
		return normalizedPath;
	}
}
