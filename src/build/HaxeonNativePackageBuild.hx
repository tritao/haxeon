package build;

import build.BuildEnvironment.BuildProfile;
import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import haxe.io.Path;
import project.ResolvedProject;

/** Executes only resolved package-native providers before a packaging backend. */
class HaxeonNativePackageBuild {
	public static function build(project:ResolvedProject, home:String, target:Target, jobs:Int, planOnly:Bool):Int {
		var environment = new BuildEnvironment(project.root, Path.join([project.root, project.manifest.outputDir]), BuildProfile.Release, target),
			plan = BuildPlanner.nativePackages(project, target, NativeArtifactDemand.Shared),
			execution = PlanLowerer.lower(plan, new LoweringContext(environment, null, project, null, home));
		if (planOnly) {
			Sys.println('Native packages [${target.toString()}]');
			Sys.print(plan.toDebugString());
			Sys.print(execution.toDebugString());
			return 0;
		}
		return ExecutionBackendFactory.create(environment, jobs).execute(execution).exitCode;
	}

	public static function nativeRoot(project:ResolvedProject, target:Target):String {
		var environment = new BuildEnvironment(project.root, Path.join([project.root, project.manifest.outputDir]), BuildProfile.Release, target);
		return Path.join([
			environment.buildRoot,
			new TargetLayout(environment).targetDirectory(),
			"jniLibs"
		]);
	}
}
