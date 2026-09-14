package build.lowering;

import build.Artifact.ArtifactKind;
import build.BuildEnvironment;
import build.BuildPlan;
import build.TargetLayout;
import build.Target.TargetOs;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ExecutionPlan;
import build.native.NativeSourcesProvider;
import build.provider.CompilerProvider;
import haxe.io.Path;
import project.ResolvedProject;

/** Selects concrete actions for logical artifacts supported by this milestone. */
class PlanLowerer {
	public static function lower(plan:BuildPlan, environment:BuildEnvironment, ?cmakePreset:String, ?project:ResolvedProject, ?output:String,
			?compilerHome:String, ?extraDefines:Array<String>):ExecutionPlan {
		var actions:Array<ExecutionAction> = [],
			layout = new TargetLayout(environment),
			artifactActions:Map<String, Array<ActionId>> = [];
		for (artifact in plan.artifacts)
			if (artifact.id.kind == ArtifactKind.NativeRuntime) {
				var runtimeActions = nativeRuntimeActions(environment, cmakePreset == null ? Std.string(environment.profile) : cmakePreset);
				actions = actions.concat(runtimeActions);
				artifactActions.set(artifact.id.key(), [runtimeActions[runtimeActions.length - 1].id]);
			}
		if (project != null) {
			for (resolvedPackage in project.packages.packages)
				if (resolvedPackage.nativeSources.length > 0) {
					var packageArtifacts = [
						for (artifact in plan.artifacts)
							if (artifact.id.packageId == resolvedPackage.name) artifact
					], nativeHome = compilerHome == null ? environment.projectRoot : compilerHome, lowered = NativeSourcesProvider.lowerPackage(resolvedPackage,
						packageArtifacts, environment, layout, nativeHome);
					actions = actions.concat(lowered.actions);
					for (key in lowered.artifactActions.keys())
						artifactActions.set(key, lowered.artifactActions.get(key));
				}
			for (artifact in plan.artifacts)
				switch artifact.id.kind {
					case HashLinkModule | WasmModule:
						var dependencies:Array<ActionId> = [];
						for (dependency in artifact.dependencies) {
							var loweredDependency = artifactActions.get(dependency.key());
							if (loweredDependency == null)
								throw 'No lowered action for required artifact $dependency';
							dependencies = dependencies.concat(loweredDependency);
						}
						var destination = output == null ? (artifact.id.kind == ArtifactKind.WasmModule ? layout.wasmModulePath(artifact.id.packageId) : layout.hashLinkModulePath(artifact.id.packageId)) : output,
							root = compilerHome == null ? environment.projectRoot : compilerHome;
						actions.push(CompilerProvider.action(project, environment, new ActionId('compile-project:${artifact.id.key()}'), dependencies,
							destination, root, extraDefines));
					default:
						if (artifact.id.kind != ArtifactKind.NativeRuntime
							&& artifact.id.kind != ArtifactKind.NativeObject
							&& artifact.id.kind != ArtifactKind.NativeStaticLibrary
							&& artifact.id.kind != ArtifactKind.NativeSharedLibrary)
							throw 'No build provider is registered for artifact ${artifact.id}';
				}
		} else if (actions.length == 0)
			throw 'No build provider is registered for artifacts in this plan';
		return new ExecutionPlan(actions);
	}

	static function nativeRuntimeActions(environment:BuildEnvironment, preset:String):Array<ExecutionAction> {
		var root = environment.projectRoot, configureId = new ActionId('cmake-configure:$preset'), buildId = new ActionId('cmake-build:$preset'),
			buildDirectory = Path.join([root, "out", "cmake", preset]), configuredGraph = Path.join([buildDirectory, "build.ninja"]), cmakeInputs = [
				Path.join([root, "CMakeLists.txt"]),
				Path.join([root, "CMakePresets.json"]),
				Path.join([root, "cmake"]),
				Path.join([root, "vendor", "hashlink", "CMakeLists.txt"])
			], runtime = Path.join([root, "out", "haxeon_runtime.hdll"]), hashlinkRoot = Path.join([root, ".tools", "hashlink"]),
			programSuffix = environment.target.os == TargetOs.Windows ? ".exe" : "", sharedSuffix = switch environment.target.os {
				case Windows: ".dll";
				case MacOS: ".dylib";
				case _: ".so";
			}, hashlink = Path.join([hashlinkRoot, "hl" + programSuffix]), profiler = Path.join([hashlinkRoot, "hlprof-live" + programSuffix]),
			libhl = Path.join([hashlinkRoot, "libhl" + sharedSuffix]);

		return [
			new ExecutionAction(configureId, [], cmakeInputs, [configuredGraph, Path.join([buildDirectory, "CMakeCache.txt"])],
				'Configure HashLink and Haxeon runtime ($preset)', Process("cmake", ["--preset", preset, "-S", root], root, new Map())),
			new ExecutionAction(buildId, [configureId], [
				Path.join([root, "native"]),
				Path.join([root, "vendor", "hashlink", "src"]),
				Path.join([root, "vendor", "hashlink", "include"])
			],
				[runtime, hashlink, profiler, libhl], 'Build HashLink and Haxeon runtime ($preset)',
				Process("cmake", ["--build", "--preset", preset], root, new Map()))
		];
	}
}
