package build.provider;

import build.AotCompiler;
import build.HaxeonSdk;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ProcessRunner;
import build.execution.CompilerClient;
import build.execution.Directories;
import compiler.CompileOptions;
import compiler.core.InternalError;
import compiler.core.UsageError;
import project.CompilerInputs;
import project.ResolvedProject;
import project.ShaderInputs;
import sys.io.File;

/** One project-level request to the persistent Haxeon compiler service. */
class CompilerProvider {
	public static function action(project:ResolvedProject, context:LoweringContext, actionId:ActionId,
			dependencies:Array<ActionId>,
			output:String, aheadOfTime:Bool = false, ?shaderRoot:String):ExecutionAction {
		if (project == null)
			throw new InternalError("CompilerProvider requires a resolved project");
		// A description of a library's API has no program to start: it types the package's modules themselves.
		var describe = context.checkOnly && context.apiJson != null, entry = project.manifest.entry;
		if (entry == null && !describe)
			throw new InternalError('Root package "${project.rootPackage.name}" must declare an "entry" for a build');
		// The compiler is built from the sources of the SDK's checkout (or `HAXEON_COMPILER_SOURCE`), with its pinned Haxe; a
		// release has neither and runs the compiler it ships (`AotCompiler.program`).
		var suffix = Sys.systemName() == "Windows" ? ".exe" : "",
			home = context.compilerHome,
			source = HaxeonSdk.source(home),
			stdlib = HaxeonSdk.stdlib(home),
			compilerSource = Sys.getEnv("HAXEON_COMPILER_SOURCE"),
			compilerSourcePath = compilerSource == null
				|| compilerSource == "" ? AotCompiler.sources(home) : compilerSource,
			compilerInputs = CompilerInputs.of(project, context.layout),
			sourcePaths = compilerInputs.sources,
			// An Android module runs in the debug host, which patches it: it is always built live, with the baseline the patches
			// are compiled against (`.hcs`) and the stable ID the host calls `main` by (`.entry`).
			android = context.environment.target.isAndroid(),
			live = !context.checkOnly && (context.live || android),
			target = aheadOfTime ? "hlc" : compilerInputs.target,
			arguments = [
				// A program compiled ahead of time is C, which the native build compiles (`ArtifactKind.CModule`).
					"--target=" + target,
					"--build-mode=" + (live || context.developmentMetadata ? "development" : "release"),
					"--output=" + output
				].concat(entry == null ? [] : ["--entry=" + entry]),
			inputs:Array<String> = [];
		if (context.webHost != null) {
			arguments.push("--export=haxeon.platform.BrowserHost.tick");
			var contract = haxe.io.Path.join([context.webHost, "nativekit_haxeon_memory_contract.json"]);
			arguments.push("--wasm-import-memory");
			if (target == "wasm-gc")
				arguments.push("--wasm-legacy-exceptions");
			arguments.push("--wasm-memory-contract=" + contract);
			inputs.push(contract);
		}
		if (context.environment.target.isWasm() && project.manifest.app != null) {
			var exports = haxe.io.Path.join([project.root, "web", "exports.txt"]);
			if (sys.FileSystem.exists(exports)) {
				for (line in File.getContent(exports).split("\n")) {
					var name = StringTools.trim(line);
					if (name != "")
						arguments.push("--export=" + name);
				}
				inputs.push(exports);
			}
		}
		// A check writes nothing, so it has no outputs and always runs; its compiler session makes a repeat cheap.
		arguments.push(context.checkOnly ? "--no-output" : "--inputs-output=" + output + ".inputs.json");
		if (describe) {
			arguments.push("--api-json=" + context.apiJson);
			for (root in project.rootPackage.sourceRoots)
				arguments.push("--api-source=" + root);
		}
		for (sourceRoot in compilerInputs.roots)
			arguments.push("--root=" + sourceRoot);
		if (shaderRoot != null) {
			var generated = ShaderInputs.sources(shaderRoot);
			arguments.push("--root=" + shaderRoot);
			arguments.push("--sources-file=" + generated);
			inputs.push(generated);
			inputs.push(haxe.io.Path.join([shaderRoot, "shaders"]));
		}
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
		// The committed bootstrap compiler predates the flag, and finds the standard library where it runs, in the checkout.
		if (!context.selfHosted)
			arguments.push("--stdlib=" + stdlib);
		// The passes are the request's (`CompileOptions`): the manifest's `inline: false` turns inlining off.
		if (context.scriptModule != null)
			arguments.push(CompileOptions.SCRIPT_MODULE + context.scriptModule);
		if (!compilerInputs.inlineEnabled)
			arguments.push("--no-inline");
		for (rule in compilerInputs.nullSafety)
			arguments.push(CompileOptions.NULL_SAFETY + rule.argument());
		// Artifact builds are the default: the module depends only on the source. Live sessions opt in.
		if (live)
			arguments.push("--live");
		if (android && !context.checkOnly) {
			arguments.push("--baseline-output=" + output + ".hcs");
			arguments.push("--entry-id-output=" + output + ".entry");
		}
		var baseline = context.baseline;
		if (baseline != null) {
			arguments.push("--baseline=" + baseline);
			inputs.push(baseline);
		}
		var command:String,
			argumentsWithLauncher:Array<String>,
			environment:Map<String, String>,
			// Where the compiler runs: the checkout for the bootstrap compiler, which reads `stdlib` there; else the SDK.
			directory = home;
		if (context.selfHosted) {
			var checkout = HaxeonSdk.requireSource(home, "--self-hosted"),
				artifact = haxe.io.Path.join([checkout, "bootstrap", "compiler.hl"]);
			command = build.HashLinkPath.executable(home);
			argumentsWithLauncher = [artifact].concat(arguments);
			inputs.push(command);
			inputs.push(artifact);
			environment = CompilerClient.runtimeLibraryEnvironment(home);
			directory = checkout;
		} else {
			// A release runs only what it ships; its action names the VM, which runs the shipped bytecode without the executable.
			var prebuilt = source == null ? AotCompiler.program(home) : null;
			command = source != null ? haxe.io.Path.join([source, ".tools", "haxe", "haxe" + suffix]) : prebuilt != null
				? prebuilt.command[0] : build.HashLinkPath.executable(home);
			argumentsWithLauncher = (compilerSourcePath == null
				? [] : build.CompilerSources.classPath(compilerSourcePath)
				.concat(["--run", "compiler.tools.HaxeonCompiler"])).concat(arguments);
			inputs.push(command);
			if (compilerSourcePath != null)
				for (root in build.CompilerSources.roots(compilerSourcePath))
					inputs.push(root);
			environment = new Map();
		}
		inputs.push(stdlib);
		for (paths in [compilerInputs.sources, compilerInputs.ffiProjections, compilerInputs.ffiInterfaces])
			for (path in paths)
				inputs.push(path);
		// Presentation, added as the compile runs; the committed bootstrap compiler predates it, so a self-hosted compile goes without.
		var reported = arguments.concat(context.reportStyle.arguments());
		var session = context.session;
		if (context.live && !context.selfHosted && session != null)
			session.liveWarmup = function():Int {
				Directories.ensure(haxe.io.Path.directory(sourceManifest));
				File.saveContent(sourceManifest, sourcePaths.join("\n") + "\n");
				// Only a resident worker can keep what it compiles; with none there is nothing to warm.
				return CompilerClient.run(command, compilerSourcePath, reported, home, context.environment.buildRoot,
					project.root, output, target, () -> 0, session, true);
			};
		var invoke = function():Int {
			var running = context.session;
			if (context.live && running != null)
				running.liveCompiled = true;
			Directories.ensure(haxe.io.Path.directory(sourceManifest));
			File.saveContent(sourceManifest, sourcePaths.join("\n") + "\n");
			return context.selfHosted ? ProcessRunner.run(command, argumentsWithLauncher, directory,
				environment) : CompilerClient.compile(command, compilerSourcePath, reported, home,
				context.environment.buildRoot,
				project.root, output, target, context.session);
		};
		if (aheadOfTime && live)
			throw new UsageError("A program compiled ahead of time cannot be patched live; build it in development mode");
		var outputs = context.checkOnly ? [] : aheadOfTime ? [
			output + ".c/hlc.h",
			output + ".c/image.c",
			output + ".inputs.json"
		] : [
			output,
			output + ".inputs.json",
			output + ".functions",
			output + ".build-id",
			output + ".descriptors",
			output + ".descriptors.json"
		];
		// A HashLink module also has its runtime identity and live description; a Wasm module has neither.
		if (compilerInputs.target == "hl" && !aheadOfTime && !context.checkOnly) {
			outputs.push(output + ".hli");
			outputs.push(output + ".live.json");
		}
		if (android && !context.checkOnly) {
			outputs.push(output + ".hcs");
			outputs.push(output + ".entry");
		}
		return new ExecutionAction(actionId, dependencies, inputs, outputs,
			'Compile Haxe package "${project.rootPackage.name}" -> $output',
			Compiler(command, argumentsWithLauncher, directory, environment, invoke), false);
	}
}
