package build.native;

import build.Artifact;
import build.Artifact.ArtifactKind;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import haxe.io.Path;
import project.ResolvedPackage;

/** Delegates an existing CMake project as one coarse native provider. */
class NativeCMakeProvider {
	public static function lowerPackage(resolvedPackage:ResolvedPackage, artifacts:Array<Artifact>, context:LoweringContext):{
		actions:Array<ExecutionAction>,
		artifactActions:Map<String, Array<ActionId>>
	} {
		var native = resolvedPackage.manifest.native;
		if (native == null || native.cmake == null)
			throw 'Package "${resolvedPackage.name}" has no native.cmake provider';
		var source = Path.normalize(Path.join([resolvedPackage.root, native.cmake.source])),
			buildDirectory = Path.join([context.layout.packageRoot(resolvedPackage.name), "cmake"]),
			output = context.layout.haxeonNativeLibraryPath(resolvedPackage.name),
			configureId = new ActionId('native-cmake-configure:${resolvedPackage.name}:${context.environment.target.toString()}'),
			buildId = new ActionId('native-cmake-build:${resolvedPackage.name}:${context.environment.target.toString()}'),
			actions = [
				new ExecutionAction(configureId, [], [source], [Path.join([buildDirectory, "CMakeCache.txt"])],
					'Configure CMake package ${resolvedPackage.name}',
					Process("cmake", ["-S", source, "-B", buildDirectory, "-DHAXEON_NATIVE_OUTPUT_DIR=" + context.layout.packageRoot(resolvedPackage.name)],
						resolvedPackage.root, new Map())),
				new ExecutionAction(buildId, [configureId], [source], [output],
					'Build CMake target ${native.cmake.target} -> $output',
					Process("cmake", ["--build", buildDirectory, "--target", native.cmake.target], resolvedPackage.root, new Map()))
			],
			artifactActions:Map<String, Array<ActionId>> = [];
		for (artifact in artifacts)
			if (artifact.id.packageId == resolvedPackage.name && artifact.id.kind == ArtifactKind.NativeSharedLibrary)
				artifactActions.set(artifact.id.key(), [buildId]);
		return {actions: actions, artifactActions: artifactActions};
	}
}
