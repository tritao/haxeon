package build.provider;

import build.lowering.LoweringContext;
import build.Target.TargetOs;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import haxe.io.Path;

/** Lowers the native HashLink/runtime artifact to its delegated CMake actions. */
class RuntimeProvider {
	public static function lower(context:LoweringContext):Array<ExecutionAction> {
		var environment = context.environment, root = environment.projectRoot, preset = context.cmakePreset,
			configureId = new ActionId('cmake-configure:$preset'), buildId = new ActionId('cmake-build:$preset'),
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
			// Let CMake/Ninja check its full dependency graph. Recursively hashing
			// HashLink's source and include trees here costs far more than an
			// incremental `cmake --build` and duplicates the native build check.
			new ExecutionAction(buildId, [configureId], [], [runtime, hashlink, profiler, libhl], 'Build HashLink and Haxeon runtime ($preset)',
				Process("cmake", ["--build", "--preset", preset], root, new Map()), true, true)
		];
	}
}
