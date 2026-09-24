package build.provider;

import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ProcessRunner;
import build.execution.CompilerClient;
import project.ResolvedProject;

/** One project-level request to the persistent Haxeon compiler service. */
class CompilerProvider {
	public static function action(project:ResolvedProject, context:LoweringContext, actionId:ActionId, dependencies:Array<ActionId>,
			output:String):ExecutionAction {
		if (project == null)
			throw "CompilerProvider requires a resolved project";
		if (project.manifest.entry == null)
			throw 'Root package "${project.rootPackage.name}" must declare an "entry" for a build';
		var suffix = Sys.systemName() == "Windows" ? ".exe" : "", compilerSource = Sys.getEnv("HAXEON_COMPILER_SOURCE"),
			compilerSourcePath = compilerSource == null
				|| compilerSource == "" ? haxe.io.Path.join([context.compilerHome, "src"]) : compilerSource,
			arguments = [
				"--target=" + (project.manifest.target == "host" ? "hl" : project.manifest.target),
				"--output=" + output,
				"--entry=" + project.manifest.entry
			], inputs:Array<String> = [];
		for (resolvedPackage in project.packages.packages) {
			for (sourceRoot in resolvedPackage.sourceRoots)
				arguments.push("--root=" + sourceRoot);
			var shouldScopeRoot = resolvedPackage.manifest.scopeSourceRoots
				&& (resolvedPackage.name != project.rootPackage.name
					|| project.manifest.entry == resolvedPackage.name
					|| StringTools.startsWith(project.manifest.entry, resolvedPackage.name + "."));
			if (shouldScopeRoot)
				for (sourceRoot in resolvedPackage.sourceRoots)
					arguments.push('--package-root=${resolvedPackage.name}=$sourceRoot');
			for (source in resolvedPackage.sources)
				arguments.push(source);
			for (projection in resolvedPackage.ffiProjections)
				arguments.push("--ffi-projection=" + projection);
			for (interfacePath in resolvedPackage.ffiInterfaces)
				arguments.push("--ffi-interface=" + interfacePath);
		}
		for (resolvedPackage in project.packages.packages)
			for (ffi in resolvedPackage.ffiImports) {
				var interfacePath = context.layout.ffiInterfacePath(resolvedPackage.name, ffi.config.name);
				arguments.push("--ffi-interface=" + interfacePath);
				inputs.push(interfacePath);
				if (ffi.config.projection) {
					var projectionPath = context.layout.ffiProjectionPath(resolvedPackage.name, ffi.config.name),
						projectionManifest = context.layout.ffiProjectionManifestPath(resolvedPackage.name, ffi.config.name);
					arguments.push("--root=" + projectionPath);
					arguments.push("--sources-file=" + projectionManifest);
					inputs.push(projectionManifest);
				}
			}
		for (define in project.manifest.defines.concat(context.extraDefines))
			arguments.push("--define=" + define);
		var command:String,
			argumentsWithLauncher:Array<String>,
			environment:Map<String, String>;
		if (context.selfHosted) {
			var artifact = haxe.io.Path.join([context.compilerHome, "bootstrap", "compiler.hl"]);
			command = haxe.io.Path.join([context.compilerHome, ".tools", "hashlink", "hl" + suffix]);
			argumentsWithLauncher = [artifact].concat(arguments);
			inputs.push(command);
			inputs.push(artifact);
			environment = runtimeLibraryEnvironment(context.compilerHome);
		} else {
			command = haxe.io.Path.join([context.compilerHome, ".tools", "haxe", "haxe" + suffix]);
			argumentsWithLauncher = ["-cp", compilerSourcePath, "--run", "compiler.tools.HaxeonCompiler"].concat(arguments);
			inputs.push(command);
			inputs.push(compilerSourcePath);
			environment = new Map();
		}
		inputs.push(haxe.io.Path.join([context.compilerHome, "stdlib"]));
		for (resolvedPackage in project.packages.packages) {
			for (source in resolvedPackage.sources)
				inputs.push(source);
			for (projection in resolvedPackage.ffiProjections)
				inputs.push(projection);
			for (interfacePath in resolvedPackage.ffiInterfaces)
				inputs.push(interfacePath);
		}
		return new ExecutionAction(actionId, dependencies, inputs, [output, output + ".functions"],
			'Compile Haxe package "${project.rootPackage.name}" -> $output',
			Compiler(command, argumentsWithLauncher, context.compilerHome, environment,
				() -> context.selfHosted ? ProcessRunner.run(command, argumentsWithLauncher, context.compilerHome,
					environment) : CompilerClient.run(command, compilerSourcePath, arguments, context.compilerHome, context.environment.buildRoot,
						project.root, () -> ProcessRunner.run(command, argumentsWithLauncher, context.compilerHome, environment))),
			false);
	}

	static function runtimeLibraryEnvironment(compilerHome:String):Map<String, String> {
		var variable = switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			case _: "LD_LIBRARY_PATH";
		};
		var directories = [
			haxe.io.Path.join([compilerHome, "out"]),
			haxe.io.Path.join([compilerHome, ".tools", "hashlink"])
		], existing = Sys.getEnv(variable);
		if (existing != null && existing.length > 0)
			directories.push(existing);
		var environment = new Map<String, String>();
		environment.set(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
		return environment;
	}
}
