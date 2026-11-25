package build.lowering;

import build.BuildEnvironment;
import build.BuildSession;
import build.HaxeonSdk;
import build.TargetLayout;
import project.ResolvedProject;

/** Immutable inputs shared by all providers while lowering one build plan. */
class LoweringContext {
	public final environment:BuildEnvironment;
	public final layout:TargetLayout;
	public final cmakePreset:String;
	public final project:Null<ResolvedProject>;
	public final output:Null<String>;
	/** Haxeon's home, the SDK the build uses (`HaxeonSdk`); by default the one the checkout being built stages. */
	public final compilerHome:String;
	public final extraDefines:Array<String>;
	public final selfHosted:Bool;

	/** Module metadata policy, independent of native optimization and debug information. */
	public final developmentMetadata:Bool;

	/** Lower CMake packages onto workspace-wide trees keyed by (source, target) instead of per package. */
	public final sharedNative:Bool;

	/** Directory of the CMake trees that project builds share (NativeCache), or null when each project builds its own. */
	public final nativeCache:Null<String>;

	/**
	 * Build for a live session (`haxeon run --watch` of an app the live host runs, `build --compiler-only --patchable`): the
	 * compiler keeps the history patches address the running module by.
	 */
	public final live:Bool;

	/**
	 * The identity state an Android edit compiles against (the `.hcs` of the module the device runs), or null for a build. The
	 * module is then a patch or a reload of that one.
	 */
	public final baseline:Null<String>;

	/** What a watching process keeps between rebuilds; null for one-shot builds. */
	public final session:Null<BuildSession>;

	/** How the compiler reports (`--verbosity=`, diagnostics): given when the compile runs, so it never enters the action's fingerprint. */
	public final reportStyle:compiler.tools.ReportStyle;

	/** Type the program without writing a module (`BuildScope.Check`): the compile is a `--no-output` request with no outputs. */
	public final checkOnly:Bool;

	public final scriptModule:Null<String>;

	public final webHost:Null<String>;

	/** Where a check also writes the root package's API model (`haxeon doc`). */
	public final apiJson:Null<String>;

	public function new(environment:BuildEnvironment, ?cmakePreset:String, ?project:ResolvedProject, ?output:String,
			?compilerHome:String,
			?extraDefines:Array<String>, ?selfHosted:Bool, ?sharedNative:Bool, ?live:Bool, ?session:BuildSession,
			?nativeCache:String,
			developmentMetadata:Bool = true, ?baseline:String, ?reportStyle:compiler.tools.ReportStyle,
			?checkOnly:Bool, ?scriptModule:String, ?webHost:String, ?apiJson:String) {
		this.apiJson = apiJson;
		this.webHost = webHost;
		this.scriptModule = scriptModule;
		this.checkOnly = checkOnly == true;
		this.reportStyle = reportStyle == null ? compiler.tools.ReportStyle.DEFAULT : reportStyle;
		this.developmentMetadata = developmentMetadata;
		this.baseline = baseline;
		this.nativeCache = nativeCache;
		this.session = session;
		this.sharedNative = sharedNative == true;
		this.live = live == true;
		this.environment = environment;
		this.layout = new TargetLayout(environment);
		this.cmakePreset = cmakePreset == null ? Std.string(environment.profile) : cmakePreset;
		this.project = project;
		this.output = output;
		this.compilerHome = compilerHome == null ? HaxeonSdk.ofCheckout(environment.projectRoot) : compilerHome;
		this.extraDefines = extraDefines == null ? [] : extraDefines.copy();
		this.selfHosted = selfHosted == true;
	}
}
