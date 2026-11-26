package build;

import build.BuildEnvironment.BuildProfile;
import build.BuildScope;
import build.execution.ActionFingerprint;
import build.execution.ActionResult.ExecutionResult;
import build.execution.ExecutionAction;
import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.execution.ExecutionPlan;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.native.NativeCache;
import build.provider.ShaderProvider;
import compiler.core.InternalError;
import compiler.tools.ReportStyle;
import compiler.tools.Verbosity;
import project.ResolvedProject;

/**
 * Project-facing structured build path shared by CLI build and run, for the host, Wasm and Android. An Android build compiles
 * the module Gradle packages and the project's native libraries (docs/design/ANDROID_BUILD.md).
 */
class HaxeonProjectBuild {
	/**
	 * The project's build directory. The instrumented flavor builds into its own (`build-instrument` beside `build`), so
	 * its compiler worker, module and instrumented native libraries never mix with the ordinary build's.
	 */
	public static function outputDirectory(project:ResolvedProject, instrument:Bool):String
		return TargetLayout.projectBuildDirectory(project.root, project.manifest.outputDir, instrument);

	/** The compiler defines that turn on the instrumented flavor's probes and scope them. */
	public static function instrumentDefines(project:ResolvedProject):Array<String> {
		var scope = project.manifest.instrument;
		return [
			"haxeon-instrument=1",
			"haxeon-instrument-include=" + scope.haxeInclude.join(","),
			"haxeon-instrument-exclude=" + scope.haxeExclude.join(",")
		];
	}

	/** Where an Android build writes its module, with `.hli` and `.hcs` beside it. */
	public static function androidModulePath(project:ResolvedProject, target:Target):String
		return new TargetLayout(new BuildEnvironment(project.root, outputDirectory(project, false),
			BuildProfile.Release,
			target)).hashLinkModulePath("app");

	public static function build(project:ResolvedProject, home:String, output:String, defines:Array<String>, jobs:Int,
			planOnly:Bool, explain:Bool,
			timingsEnabled:Bool, resolutionMs:Float, selfHosted:Bool = false, scope:BuildScope = Full,
			live:Bool = false, instrument:Bool = false,
			?session:BuildSession, developmentMetadata:Bool = true, ?target:Target, ?baseline:String,
			?style:ReportStyle, aheadOfTime:Bool = false, ?scriptModule:String, ?webHost:String,
			consoleProgram:Bool = false, ?apiJson:String):Int {
		var shown = style == null ? ReportStyle.DEFAULT : style;
		var buildTarget = target == null ? Target.detectHost() : target;
		if (!buildTarget.isWasm() && !buildTarget.isAndroid() && !buildTarget.equals(Target.detectHost()))
			throw new InternalError('The structured build supports the host, wasm32 and android targets, not "$buildTarget"');
		var timings = new BuildTimings();
		timings.add("resolve", resolutionMs);
		if (instrument)
			defines = defines.concat(instrumentDefines(project));
		var environment = new BuildEnvironment(project.root, outputDirectory(project, instrument), BuildProfile.Release,
			buildTarget, null,
			instrument ? project.manifest.instrument : null),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target,
				webHost != null ? NativeArtifactDemand.None : NativeArtifactDemand.Shared,
				aheadOfTime, webHost != null, consoleProgram),
			lowerStarted = Sys.time() * 1000.0,
			execution = PlanLowerer.lower(plan,
				new LoweringContext(
					environment,
					null,
					project,
					output,
					home,
					defines,
					selfHosted,
					false,
					live,
					session,
					// Android packages build their own trees, publishing into jniLibs, as Gradle packages them.
					buildTarget.isAndroid() ? null : NativeCache.root(home, environment),
					developmentMetadata,
					baseline,
					// `--timings` asks for the compiler's reports too: the scripts that measure builds read them.
					timingsEnabled ? shown.withVerbosity(Verbosity.Diagnostic) : shown,
					scope == Check,
					scriptModule,
					webHost,
					apiJson
				));
		switch scope {
			case Full:
			case CompilerOnly | Edit:
				execution = compilerExecution(execution);
			case Check | Module:
				execution = checkExecution(execution);
		}
		timings.addElapsed("plan and lower", lowerStarted);
		if (planOnly) {
			Sys.println('Build ${project.rootPackage.name} [${new TargetLayout(environment).targetDirectory()}]');
			Sys.println(plan.toDebugString());
			if (explain)
				Sys.print(plan.toExplainString());
			Sys.println("Actions:");
			Sys.print(execution.toDebugString());
			if (timingsEnabled)
				Sys.print(timings.toString());
			return 0;
		}
		var result = scope == Edit && session != null ? executeEdit(execution, environment, jobs, session,
			shown.verbosity) : ExecutionBackendFactory.create(environment, jobs, null, session,
			shown.verbosity).execute(execution);
		timings.add("execute", result.elapsedMs);
		if (explain)
			Sys.print(plan.toExplainString());
		if (timingsEnabled)
			Sys.print(timings.toString());
		return result.exitCode;
	}

	/**
		An `Edit` build: each compile runs unchecked, after its recorded fingerprint is dropped, and records its fingerprint when the
		watch is idle. The digest store is written then too.
	**/
	static function executeEdit(plan:ExecutionPlan, environment:BuildEnvironment, jobs:Int, session:BuildSession,
			verbosity:Verbosity):ExecutionResult {
		var target = environment.target.toString(), buildRoot = environment.buildRoot;
		for (action in plan.actions)
			ActionFingerprint.forget(buildRoot, action);
		// Run on every build (`alwaysRun`), so the executor neither checks nor records a fingerprint.
		var unchecked = new ExecutionPlan([
			for (action in plan.actions)
				new ExecutionAction(action.id, action.dependencies, action.inputs, action.outputs, action.description,
				action.action,
				false, true)
		]);
		var result = ExecutionBackendFactory.create(environment, jobs, null, session, verbosity,
			false).execute(unchecked);
		if (result.exitCode == 0)
			for (action in plan.actions)
				// From the inputs the compiler reported reading, so an edit saved since the compile is not taken as compiled.
				session.whenIdle("fingerprint:" + action.id.key(),
					() -> ActionFingerprint.save(buildRoot, action,
					ActionFingerprint.compute(action, buildRoot, target, [], session.digests, true)));
		session.whenIdle("digests", session.digests.save);
		return result;
	}

	/** The compile and every action it depends on (the FFI imports it reads), without the native libraries. */
	static function checkExecution(plan:ExecutionPlan):ExecutionPlan {
		var needed:Map<String, Bool> = [], pending = [];
		for (action in plan.actions)
			if (action.action.match(Compiler(_, _, _, _, _)))
				pending.push(action.id);
		if (pending.length == 0)
			throw new InternalError("Build plan has no compiler action");
		while (pending.length > 0) {
			var id = pending.pop();
			if (needed.exists(id.key()))
				continue;
			needed.set(id.key(), true);
			var action = plan.action(id);
			if (action != null)
				for (dependency in action.dependencies)
					pending.push(dependency);
		}
		return new ExecutionPlan([for (action in plan.actions) if (needed.exists(action.id.key())) action]);
	}

	static function compilerExecution(plan:ExecutionPlan):ExecutionPlan {
		var actions = [];
		for (action in plan.actions)
			switch action.action {
				case Compiler(_, _, _, _, _):
					var dependencies = action.dependencies.filter(ShaderProvider.owns);
					actions.push(new ExecutionAction(action.id, dependencies, action.inputs, action.outputs,
						action.description, action.action, false, action.alwaysRun));
				case Process(_, _, _, _) if (ShaderProvider.owns(action.id)):
					actions.push(action);
				case Process(_, _, _, _):
			}
		if (actions.length == 0)
			throw new InternalError("Build plan has no compiler action");
		return new ExecutionPlan(actions);
	}
}
