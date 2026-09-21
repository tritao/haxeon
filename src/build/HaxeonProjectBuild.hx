package build;

import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.BuildEnvironment.BuildProfile;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.ResolvedProject;

/** Project-facing structured build path shared by CLI build and run. */
class HaxeonProjectBuild {
	public static function build(project:ResolvedProject, home:String, output:String, defines:Array<String>, jobs:Int, planOnly:Bool, explain:Bool,
			timingsEnabled:Bool, resolutionMs:Float, selfHosted:Bool = false):Int {
		if (project.manifest.target != "host")
			throw 'The structured native package build currently supports target "host", got "${project.manifest.target}"';
		var timings = new BuildTimings();
		timings.add("resolve", resolutionMs);
		var environment = new BuildEnvironment(project.root, Path.join([project.root, project.manifest.outputDir]), BuildProfile.Release),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
			lowerStarted = Date.now().getTime(),
			execution = PlanLowerer.lower(plan, new LoweringContext(environment, null, project, output, home, defines, selfHosted));
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
}
