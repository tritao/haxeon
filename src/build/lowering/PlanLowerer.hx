package build.lowering;

import build.Artifact.ArtifactKind;
import build.BuildPlan;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionPlan;
import build.native.NativeCMakeProvider;
import build.native.NativeSourcesProvider;
import build.provider.CompilerProvider;
import build.provider.RuntimeProvider;

/** Orchestrates provider lowering without owning provider-specific commands. */
class PlanLowerer {
	public static function lower(plan:BuildPlan, context:LoweringContext):ExecutionPlan {
		var actions:Array<ExecutionAction> = [],
			artifactActions:Map<String, Array<ActionId>> = [];
		for (artifact in plan.artifacts)
			if (artifact.id.kind == ArtifactKind.NativeRuntime) {
				var runtimeActions = RuntimeProvider.lower(context);
				actions = actions.concat(runtimeActions);
				artifactActions.set(artifact.id.key(), [runtimeActions[runtimeActions.length - 1].id]);
			}

		var project = context.project;
		if (project != null) {
			for (resolvedPackage in project.packages.packages)
				if (resolvedPackage.nativeSources.length > 0
					|| (resolvedPackage.manifest.native != null && resolvedPackage.manifest.native.cmake != null)) {
					var packageArtifacts = [
						for (artifact in plan.artifacts)
							if (artifact.id.packageId == resolvedPackage.name) artifact
					], lowered = resolvedPackage.nativeSources.length > 0 ? NativeSourcesProvider.lowerPackage(resolvedPackage, packageArtifacts,
						context) : NativeCMakeProvider.lowerPackage(resolvedPackage, packageArtifacts, context);
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
						var destination = context.output == null ? (artifact.id.kind == ArtifactKind.WasmModule ? context.layout.wasmModulePath(artifact.id.packageId) : context.layout.hashLinkModulePath(artifact.id.packageId)) : context.output;
						actions.push(CompilerProvider.action(project, context, new ActionId('compile-project:${artifact.id.key()}'), dependencies,
							destination));
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
}
