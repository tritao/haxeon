package build.provider;

import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ProcessRunner;
import build.execution.CompilerClient;
import build.execution.Directories;
import project.CompilerInputs;
import project.ResolvedProject;
import sys.io.File;

/** One project-level request to the persistent Haxeon compiler service. */
class CompilerProvider {
	public static function action(project:ResolvedProject, context:LoweringContext, actionId:ActionId,
			dependencies:Array<ActionId>,
			output:String):ExecutionAction {
		if (project == null)
			throw "CompilerProvider requires a resolved project";
		if (project.manifest.entry == null)
			throw 'Root package "${project.rootPackage.name}" must declare an "entry" for a build';
		var suffix = Sys.systemName() == "Windows" ? ".exe" : "",
			compilerSource = Sys.getEnv("HAXEON_COMPILER_SOURCE"),
			compilerSourcePath = compilerSource == null
				|| compilerSource == "" ? haxe.io.Path.join([context.compilerHome, "src"]) : compilerSource,
			compilerInputs = CompilerInputs.of(project, context.layout),
			sourcePaths = compilerInputs.sources,
			arguments = [
				"--target=" + compilerInputs.target,
				"--build-mode=" + (context.live || context.developmentMetadata ? "development" : "release"),
				"--output=" + output,
				"--entry=" + project.manifest.entry,
				"--inputs-output=" + output + ".inputs.json"
			],
			inputs:Array<String> = [];
		for (sourceRoot in compilerInputs.roots)
			arguments.push("--root=" + sourceRoot);
		for (root in compilerInputs.packageRoots)
			arguments.push('--package-root=${root.packageName}=${root.path}');
		for (projection in compilerInputs.ffiProjections)
			arguments.push("--ffi-projection=" + projection);
		for (interfacePath in compilerInputs.ffiInterfaces)
			arguments.push("--ffi-interface=" + interfacePath);
		// The FFI imports' outputs, which this module's FFI actions write first.
		for (ffi in compilerInputs.generatedFfi) {
			arguments.push("--ffi-interface=" + ffi.interfacePath);
			inputs.push(ffi.interfacePath);
			var projectionRoot = ffi.projectionRoot, projectionManifest = ffi.projectionManifest;
			if (projectionRoot != null && projectionManifest != null) {
				arguments.push("--root=" + projectionRoot);
				arguments.push("--sources-file=" + projectionManifest);
				inputs.push(projectionManifest);
			}
		}
		// Keep the process command line short on Windows; CompilerArguments already supports
		// newline-delimited source manifests, as used by the compiler bootstrap.
		var sourceManifest = output + ".sources.txt";
		arguments.push("--sources-file=" + sourceManifest);
		for (define in compilerInputs.defines.concat(context.extraDefines))
			arguments.push("--define=" + define);
		// The passes are the request's (`CompileOptions`): the manifest's `inline: false` turns inlining off.
		if (!compilerInputs.inlineEnabled)
			arguments.push("--no-inline");
		// Artifact builds are the default: the module depends only on the source. Live sessions opt in.
		if (context.live)
			arguments.push("--live");
		var command:String,
			argumentsWithLauncher:Array<String>,
			environment:Map<String, String>;
		if (context.selfHosted) {
			var artifact = haxe.io.Path.join([context.compilerHome, "bootstrap", "compiler.hl"]);
			command = haxe.io.Path.join([build.HashLinkPath.directory(context.compilerHome), "hl" + suffix]);
			argumentsWithLauncher = [artifact].concat(arguments);
			inputs.push(command);
			inputs.push(artifact);
			environment = CompilerClient.runtimeLibraryEnvironment(context.compilerHome);
		} else {
			command = haxe.io.Path.join([context.compilerHome, ".tools", "haxe", "haxe" + suffix]);
			argumentsWithLauncher = build.CompilerSources.classPath(compilerSourcePath).concat([
				"--run",
				"compiler.tools.HaxeonCompiler"
			]).concat(arguments);
			inputs.push(command);
			for (root in build.CompilerSources.roots(compilerSourcePath))
				inputs.push(root);
			environment = new Map();
		}
		inputs.push(haxe.io.Path.join([context.compilerHome, "stdlib"]));
		for (paths in [compilerInputs.sources, compilerInputs.ffiProjections, compilerInputs.ffiInterfaces])
			for (path in paths)
				inputs.push(path);
		var session = context.session;
		if (context.live && !context.selfHosted && session != null)
			session.liveWarmup = function():Int {
				Directories.ensure(haxe.io.Path.directory(sourceManifest));
				File.saveContent(sourceManifest, sourcePaths.join("\n") + "\n");
				// Only a resident worker can keep what it compiles; with none there is nothing to warm.
				return CompilerClient.run(command, compilerSourcePath, arguments, context.compilerHome,
					context.environment.buildRoot, project.root, () -> 0,
					session, true);
			};
		var invoke = function():Int {
			var running = context.session;
			if (context.live && running != null)
				running.liveCompiled = true;
			Directories.ensure(haxe.io.Path.directory(sourceManifest));
			File.saveContent(sourceManifest, sourcePaths.join("\n") + "\n");
			return context.selfHosted ? ProcessRunner.run(command, argumentsWithLauncher, context.compilerHome,
				environment) : CompilerClient.compile(command, compilerSourcePath, arguments, context.compilerHome,
				context.environment.buildRoot, project.root, context.session);
		};
		var outputs = [
			output,
			output + ".inputs.json",
			output + ".functions",
			output + ".build-id",
			output + ".descriptors",
			output + ".descriptors.json"
		];
		// A HashLink module also has its runtime identity and live description; a Wasm module has neither.
		if (compilerInputs.target == "hl") {
			outputs.push(output + ".hli");
			outputs.push(output + ".live.json");
		}
		return new ExecutionAction(actionId, dependencies, inputs, outputs,
			'Compile Haxe package "${project.rootPackage.name}" -> $output',
			Compiler(command, argumentsWithLauncher, context.compilerHome, environment, invoke), false);
	}
}
