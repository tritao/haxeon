package build.native;

import build.Artifact;
import build.Artifact.ArtifactKind;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import haxe.io.Path;
import project.ResolvedPackage;

/** Lowers C sources to object files and only the native library artifacts in the plan. */
class NativeSourcesProvider {
	public static function lowerPackage(resolvedPackage:ResolvedPackage, artifacts:Array<Artifact>, context:LoweringContext):{
		actions:Array<ExecutionAction>,
		artifactActions:Map<String, Array<ActionId>>
	} {
		var library = new NativeLibrary(resolvedPackage.name, resolvedPackage.nativeSources, resolvedPackage.includeDirs),
			environment = context.environment,
			layout = context.layout,
			toolchain = new NativeToolchain(environment),
			hashlinkIncludes = Path.join([context.compilerHome, "vendor", "hashlink", "src"]),
			includeDirs = library.includeDirs.concat([hashlinkIncludes]),
			actions:Array<ExecutionAction> = [],
			artifactActions:Map<String, Array<ActionId>> = [],
			objectPaths:Map<String, String> = [];
		for (artifact in artifacts)
			if (artifact.id.packageId == library.packageName && artifact.id.kind == ArtifactKind.NativeObject) {
				var sourceRelative = artifact.details.get("source"),
					ffiName = artifact.details.get("ffi"),
					source = ffiName == null ? Path.join([resolvedPackage.root, sourceRelative]) : layout.ffiThunkSourcePath(library.packageName, ffiName),
					output = layout.objectPath(library.packageName, sourceRelative),
					id = new ActionId('native-compile:${artifact.id.key()}'),
					inputs = [source],
					dependencies:Array<ActionId> = [
						for (dependency in artifact.dependencies)
							switch dependency.kind {
								case ArtifactKind.FfiInterface:
									new ActionId('ffi-import:${dependency.key()}');
								case _:
									throw 'Native object ${artifact.id} has unsupported dependency $dependency';
							}
					];
				if (ffiName == null)
					inputs = inputs.concat(NativeDependencyScanner.dependencies(source, includeDirs));
				else {
					var ffi = [
						for (candidate in resolvedPackage.ffiImports)
							if (candidate.config.name == ffiName) candidate
					];
					if (ffi.length != 1)
						throw 'Native object ${artifact.id} refers to missing FFI import $ffiName';
					inputs = inputs.concat([ffi[0].header]).concat(ffi[0].includes);
				}
				var cxx = artifact.details.get("language") == "c++" || toolchain.isCxxSource(source),
					language = cxx ? "C++" : "C",
					standard = artifact.details.get("standard");
				objectPaths.set(artifact.id.key(), output);
				actions.push(new ExecutionAction(id, dependencies, inputs, [output], 'Compile $language $source -> $output',
					Process(toolchain.compileCommand(source), toolchain.compileArguments(source, output, includeDirs, standard), resolvedPackage.root,
						new Map())));
				artifactActions.set(artifact.id.key(), [id]);
			}
		for (artifact in artifacts)
			if (artifact.id.packageId == library.packageName
				&& (artifact.id.kind == ArtifactKind.NativeStaticLibrary
					|| artifact.id.kind == ArtifactKind.NativeSharedLibrary
					|| artifact.id.kind == ArtifactKind.FfiNativeSharedLibrary)) {
				var objects = [for (dependency in artifact.dependencies) objectPaths.get(dependency.key())],
					dependencies = [
						for (dependency in artifact.dependencies)
							new ActionId('native-compile:${dependency.key()}')
					],
					isStatic = artifact.id.kind == ArtifactKind.NativeStaticLibrary,
					ffiName = artifact.details.get("ffi"),
					output = isStatic ? layout.nativeStaticLibraryPath(library.packageName,
						library.packageName) : ffiName == null ? layout.haxeonNativeLibraryPath(library.packageName) : layout.ffiNativeLibraryPath(library.packageName,
							ffiName),
					id = new ActionId('${isStatic ? "native-archive" : "native-link"}:${artifact.id.key()}'),
					command = isStatic ? toolchain.archiveCommand() : toolchain.sharedCommand(),
					arguments = isStatic ? toolchain.archiveArguments(output, objects) : toolchain.sharedArguments(output, objects);
				actions.push(new ExecutionAction(id, dependencies, objects, [output],
					'${isStatic ? "Archive" : "Link shared library"} ${ffiName == null ? library.packageName : library.packageName + " FFI " + ffiName} -> $output',
					Process(command, arguments, resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [id]);
			}
		return {actions: actions, artifactActions: artifactActions};
	}
}
