package build;

import build.execution.Executor;
import build.lowering.PlanLowerer;
import build.BuildEnvironment.BuildProfile;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.ResolvedProject;

/** Project-facing structured build path shared by CLI build and run. */
class HaxeonProjectBuild {
	public static function build(project:ResolvedProject, home:String, output:String, defines:Array<String>, jobs:Int, planOnly:Bool):Int {
		if (project.manifest.target != "host")
			throw 'The structured native package build currently supports target "host", got "${project.manifest.target}"';
		var environment = new BuildEnvironment(project.root, Path.join([project.root, project.manifest.outputDir]), BuildProfile.Release),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target),
			execution = PlanLowerer.lower(plan, environment, null, project, output, home, defines);
		if (planOnly) {
			Sys.println('Build ${project.rootPackage.name} [host]');
			Sys.println(plan.toDebugString());
			Sys.println("Actions:");
			Sys.print(execution.toDebugString());
			return 0;
		}
		var result = new Executor(environment, jobs).execute(execution);
		return result.exitCode;
	}
}
