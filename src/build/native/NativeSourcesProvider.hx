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
					source = Path.join([resolvedPackage.root, sourceRelative]),
					output = layout.objectPath(library.packageName, sourceRelative),
					id = new ActionId('native-compile:${artifact.id.key()}'),
					inputs = [source].concat(NativeDependencyScanner.dependencies(source, includeDirs));
				objectPaths.set(artifact.id.key(), output);
				actions.push(new ExecutionAction(id, [], inputs, [output], 'Compile C $source -> $output',
					Process(toolchain.compileCommand(), toolchain.compileArguments(source, output, includeDirs), resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [id]);
			}
		for (artifact in artifacts)
			if (artifact.id.packageId == library.packageName
				&& (artifact.id.kind == ArtifactKind.NativeStaticLibrary || artifact.id.kind == ArtifactKind.NativeSharedLibrary)) {
				var objects = [for (dependency in artifact.dependencies) objectPaths.get(dependency.key())],
					dependencies = [
						for (dependency in artifact.dependencies)
							new ActionId('native-compile:${dependency.key()}')
					],
					isStatic = artifact.id.kind == ArtifactKind.NativeStaticLibrary,
					output = isStatic ? layout.nativeStaticLibraryPath(library.packageName,
						library.packageName) : layout.haxeonNativeLibraryPath(library.packageName),
					id = new ActionId('${isStatic ? "native-archive" : "native-link"}:${artifact.id.key()}'),
					command = isStatic ? toolchain.archiveCommand() : toolchain.sharedCommand(),
					arguments = isStatic ? toolchain.archiveArguments(output, objects) : toolchain.sharedArguments(output, objects);
				actions.push(new ExecutionAction(id, dependencies, objects, [output],
					'${isStatic ? "Archive" : "Link shared library"} ${library.packageName} -> $output',
					Process(command, arguments, resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [id]);
			}
		return {actions: actions, artifactActions: artifactActions};
	}
}
