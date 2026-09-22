package build;

import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.execution.ExecutionAction;
import build.execution.ExecutionPlan;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.BuildEnvironment.BuildProfile;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.ResolvedProject;

/** Project-facing structured build path shared by CLI build and run. */
class HaxeonProjectBuild {
	public static function build(project:ResolvedProject, home:String, output:String, defines:Array<String>, jobs:Int, planOnly:Bool, explain:Bool,
			timingsEnabled:Bool, resolutionMs:Float, selfHosted:Bool = false, compilerOnly:Bool = false):Int {
		if (project.manifest.target != "host")
			throw 'The structured native package build currently supports target "host", got "${project.manifest.target}"';
		var timings = new BuildTimings();
		timings.add("resolve", resolutionMs);
		var environment = new BuildEnvironment(project.root, Path.join([project.root, project.manifest.outputDir]), BuildProfile.Release),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
			lowerStarted = Sys.time() * 1000.0,
			execution = PlanLowerer.lower(plan, new LoweringContext(environment, null, project, output, home, defines, selfHosted));
		if (compilerOnly)
			execution = compilerExecution(execution);
		timings.addElapsed("plan and lower", lowerStarted);
		if (planOnly) {
			Sys.println('Build ${project.rootPackage.name} [host]');
			Sys.println(plan.toDebugString());
			if (explain)
				Sys.print(plan.toExplainString());
			Sys.println("Actions:");
			Sys.print(execution.toDebugString());
			if (timingsEnabled)
				Sys.print(timings.toString());
			return 0;
		}
		var result = ExecutionBackendFactory.create(environment, jobs).execute(execution);
		timings.add("execute", result.elapsedMs);
		if (explain)
			Sys.print(plan.toExplainString());
		if (timingsEnabled)
			Sys.print(timings.toString());
		return result.exitCode;
	}

	static function compilerExecution(plan:ExecutionPlan):ExecutionPlan {
		var actions = [];
		for (action in plan.actions)
			switch action.action {
				case Compiler(_, _, _, _, _):
					actions.push(new ExecutionAction(action.id, [], action.inputs, action.outputs, action.description, action.action, false, action.alwaysRun));
				case Process(_, _, _, _):
			}
		if (actions.length == 0)
			throw "Build plan has no compiler action";
		return new ExecutionPlan(actions);
	}
}
