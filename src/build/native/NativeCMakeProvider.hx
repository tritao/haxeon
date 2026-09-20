package build.native;

import build.Artifact;
import build.Artifact.ArtifactKind;
import build.ArtifactId;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import haxe.io.Path;
import project.FfiManifest.ResolvedFfiImport;
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
		var source = Path.normalize(Path.join([resolvedPackage.root, native.cmake.source])), layout = context.layout,
			buildDirectory = Path.join([layout.packageRoot(resolvedPackage.name), "cmake"]), output = layout.haxeonNativeLibraryPath(resolvedPackage.name),
			outputDirectory = Path.directory(output),
			configureId = new ActionId('native-cmake-configure:${resolvedPackage.name}:${context.environment.target.toString()}'),
			buildId = new ActionId('native-cmake-build:${resolvedPackage.name}:${context.environment.target.toString()}'),
			toolchain = new NativeToolchain(context.environment), actions = [
				new ExecutionAction(configureId, [], [source], [Path.join([buildDirectory, "CMakeCache.txt"])],
					'Configure CMake package ${resolvedPackage.name}',
					Process("cmake", [
						"-S",
						source,
						"-B",
						buildDirectory,
						"-DHAXEON_NATIVE_OUTPUT_DIR=" + outputDirectory,
						"-DHAXEON_TARGET=" + context.environment.target.toString()
					],
						resolvedPackage.root, new Map())),
				new ExecutionAction(buildId, [configureId], [source], [output], 'Build CMake target ${native.cmake.target} -> $output',
					Process("cmake", ["--build", buildDirectory, "--target", native.cmake.target], resolvedPackage.root, new Map()))
			], artifactActions:Map<String, Array<ActionId>> = [];
		for (artifact in artifacts)
			if (artifact.id.packageId == resolvedPackage.name && artifact.id.kind == ArtifactKind.NativeSharedLibrary)
				artifactActions.set(artifact.id.key(), [buildId]);
		for (artifact in artifacts)
			if (artifact.id.packageId == resolvedPackage.name && artifact.id.kind == ArtifactKind.FfiNativeSharedLibrary) {
				var ffiName = artifact.details.get("ffi");
				if (ffiName == null)
					throw 'CMake FFI shared library ${artifact.id} is missing its FFI name';
				var imports = [
					for (candidate in resolvedPackage.ffiImports)
						if (candidate.config.name == ffiName) candidate
				];
				if (imports.length != 1)
					throw 'CMake FFI shared library ${artifact.id} refers to missing FFI import $ffiName';
				var ffi:ResolvedFfiImport = imports[0],
					sourceRelative = 'ffi/$ffiName/$ffiName-thunks.cpp',
					thunkSource = layout.ffiThunkSourcePath(resolvedPackage.name, ffiName),
					thunkObject = layout.objectPath(resolvedPackage.name, sourceRelative),
					compileId = new ActionId('native-compile:${artifact.id.key()}'),
					compileDependencies:Array<ActionId> = [],
					compileInputs = [thunkSource, ffi.header].concat(ffi.includes),
					includeDirs = resolvedPackage.includeDirs.concat(ffi.includes);
				compileDependencies.push(new ActionId('ffi-import:'
					+ new ArtifactId(resolvedPackage.name, ArtifactKind.FfiInterface, context.environment.target, ffiName).key()));
				actions.push(new ExecutionAction(compileId, compileDependencies, compileInputs, [thunkObject], 'Compile C++ $thunkSource -> $thunkObject',
					Process(toolchain.compileCommand(thunkSource), toolchain.compileArguments(thunkSource, thunkObject, includeDirs, ffi.config.standard),
						resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [compileId]);

				var ffiOutput = layout.ffiNativeLibraryPath(resolvedPackage.name, ffiName),
					linkId = new ActionId('native-link:${artifact.id.key()}'),
					linkDependencies:Array<ActionId> = [compileId],
					linkInputs:Array<String> = [thunkObject, output];
				for (dependency in artifact.dependencies)
					if (dependency.kind == ArtifactKind.NativeSharedLibrary)
						linkDependencies.push(buildId);
				actions.push(new ExecutionAction(linkId, linkDependencies, linkInputs, [ffiOutput],
					'Link shared library ${resolvedPackage.name} FFI $ffiName -> $ffiOutput',
					Process(toolchain.sharedCommand(), toolchain.sharedArguments(ffiOutput, [thunkObject], [output], [outputDirectory]), resolvedPackage.root,
						new Map())));
				artifactActions.set(artifact.id.key(), [linkId]);
			}
		return {actions: actions, artifactActions: artifactActions};
	}
}
