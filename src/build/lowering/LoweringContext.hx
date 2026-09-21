package build.lowering;

import build.BuildEnvironment;
import build.TargetLayout;
import project.ResolvedProject;

/** Immutable inputs shared by all providers while lowering one build plan. */
class LoweringContext {
	public final environment:BuildEnvironment;
	public final layout:TargetLayout;
	public final cmakePreset:String;
	public final project:Null<ResolvedProject>;
	public final output:Null<String>;
	public final compilerHome:String;
	public final extraDefines:Array<String>;
	public final selfHosted:Bool;

	public function new(environment:BuildEnvironment, ?cmakePreset:String, ?project:ResolvedProject, ?output:String, ?compilerHome:String,
			?extraDefines:Array<String>, ?selfHosted:Bool) {
		this.environment = environment;
		this.layout = new TargetLayout(environment);
		this.cmakePreset = cmakePreset == null ? Std.string(environment.profile) : cmakePreset;
		this.project = project;
		this.output = output;
		this.compilerHome = compilerHome == null ? environment.projectRoot : compilerHome;
		this.extraDefines = extraDefines == null ? [] : extraDefines.copy();
		this.selfHosted = selfHosted == true;
	}
}
