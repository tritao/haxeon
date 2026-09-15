package build;

import build.Artifact.ArtifactKind.NativeRuntime;
import build.Artifact.ArtifactKind.Diagnostics;
import build.Artifact.ArtifactKind.Executable;
import build.Artifact.ArtifactKind.HashLinkModule;
import build.Artifact.ArtifactKind.NativeObject;
import build.Artifact.ArtifactKind.NativeSharedLibrary;
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
			nativeStatic = new Map<String, ArtifactId>();
		for (resolvedPackage in project.packages.packages)
			if (resolvedPackage.nativeSources.length > 0
				|| (resolvedPackage.manifest.native != null && resolvedPackage.manifest.native.cmake != null)) {
				var objects:Array<ArtifactId> = [];
				if (NativeArtifactDemands.includes(nativeDemand, NativeStaticLibrary)
					|| NativeArtifactDemands.includes(nativeDemand, NativeSharedLibrary))
					for (source in resolvedPackage.nativeSources) {
						var relative = relativePath(resolvedPackage.root, source),
							id = new ArtifactId(resolvedPackage.name, NativeObject, target, relative),
							details:Map<String, String> = ["source" => relative];
						artifacts.push(new Artifact(id, [], details));
						objects.push(id);
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
		var kind = switch target {
			case _: project.manifest.target == "wasm32" ? WasmModule : HashLinkModule;
		};
		if (intent == Check)
			kind = Diagnostics;
		var moduleId = new ArtifactId(project.rootPackage.name, kind, target);
		artifacts.push(new Artifact(moduleId, libraryRequirements, ["entry" => project.manifest.entry == null ? "" : project.manifest.entry]));
		return new BuildPlan([moduleId], artifacts);
	}

	/** Native-only request used by package consumers such as Android packaging. */
	public static function nativePackages(project:ResolvedProject, target:Target, nativeDemand:NativeArtifactDemand):BuildPlan {
		var full = BuildPlanner.project(project, BuildIntent.Build, target, nativeDemand),
			artifacts:Array<Artifact> = [
				for (artifact in full.artifacts)
					if (artifact.id.kind == NativeObject
						|| artifact.id.kind == NativeStaticLibrary
						|| artifact.id.kind == NativeSharedLibrary) artifact
			],
			requested:Array<ArtifactId> = [
				for (artifact in artifacts)
					if (artifact.id.kind == NativeStaticLibrary || artifact.id.kind == NativeSharedLibrary) artifact.id
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
