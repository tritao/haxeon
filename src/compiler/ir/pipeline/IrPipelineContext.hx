package compiler.ir.pipeline;

import compiler.ir.tools.IrInstrumentation.IrInstrumentationScope;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrPassScratch;
import compiler.ir.verify.IrVerifyMemo;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.reuse.IrStageMemos;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.pipeline.TargetProfile.TargetKind;

/**
 * What the stages of one `IrPipeline` run read besides the program: the target, the program tables and caches the passes take, and
 * the check-mode state. One per run; the stage lists themselves hold no build state.
 */
class IrPipelineContext {
	public final profile:TargetProfile;

	/** The value-array lane layout of the target; null when the build has none (`IrProgramAssembler.generate`). */
	public final laneTarget:Null<IrValueLaneTarget>;

	// Assembly (`IrPipeline.assembly`).
	public var entryPoint:Null<String> = null;
	public var staticInitializers:Null<Array<IrFunction>> = null;
	public var exportedFunctions:Null<Array<String>> = null;
	public var canonicalObjects:Null<Array<IrObject>> = null;

	/** The session's memos of the stages (`IrStageMemos`); null in a compile that keeps no session. */
	public var stageMemos:Null<IrStageMemos> = null;

	/** The roots of the early prune: the entry function, the static initializers and the exported functions. */
	public var pruneRoots:Array<String> = [];

	// Target lowering (`IrPipeline.target`).
	public var livePatching:Bool = false;
	public var developmentMetadata:Bool = false;

	/** The build's sources, for what reports positions in them (`SourceAnchors`). */
	public var sources = new compiler.core.SourceAnchor.SourceAnchors([]);

	public var reflectable:Null<Array<String>> = null;
	public var inlineCache:Null<IrInlineCache> = null;
	public var instrumentScope:Null<IrInstrumentationScope> = null;
	public var verifyMemo:Null<IrVerifyMemo> = null;

	/** The tables the passes over bodies before the inliner reuse. */
	public final passScratch = new IrPassScratch();

	/** The compile's passes and self-checks (`CompileOptions`): with `checkReuse`, the memoized verification is followed by a full one. */
	public var options = new compiler.CompileOptions();

	/** The object table scalar replacement reads, taken before it runs. */
	public var scalarObjects:Null<IrObjectTable> = null;

	/** What the inliner changed (`IrInliner.run`), for the functions a build lowers and patches again. */
	public var inlinerChanged:Array<String> = [];

	// Check mode of the early prune (`IrEntryPrune`).

	/**
	 * The build decides from what its entry reaches (`IrEntryPrune.walk`): every build but a live HashLink one, whose host can call any function (Wasm has no live host).
	 * Which natives reached code calls decides whether the program reflects over object layouts (`IrObjectReflection.usedByProgram`).
	 */
	public var walkFromEntry:Bool = false;

	/** The build also prunes the program from its entry (`IrEntryPrune.run`); it then walks from it too. */
	public var pruneFromEntry:Bool = false;

	/** What the prune removed; empty without it. */
	public var pruned:Map<String, Bool> = [];

	/**
	 * The prune keeps every method of every class in its table, one nothing reaches with a declaration stub: a live layout, which
	 * a later edit's reach must not move (`IrEntryPrune.run`).
	 */
	public var declaredMethods:Bool = false;

	/** The functions the prune gave a declaration stub; empty without it. */
	public var stubbed:Map<String, Bool> = [];

	/**
	 * With `declaredMethods`, the bodies the prune removed or stubbed: a live layout's runtime surface is what they need too, since
	 * natives come before every function slot and a later edit may reach them (`IrProgramAssembler.finish`).
	 */
	public var unreachedBodies:Array<IrFunction> = [];

	/** Where the stages record their time and allocation, when the compile reports them; null for pipelines that do not. */
	public var meter:Null<compiler.core.IrPassMeter> = null;

	/** The (class, method) table entries the early prune removed, as `class\u0001method`. */
	public var prunedMethods:Map<String, Bool> = [];

	/** Set at the prune point: the stages after it check that nothing calls what it removed. */
	public var checkPrune:Bool = false;

	public function new(profile:TargetProfile, laneTarget:Null<IrValueLaneTarget>) {
		this.profile = profile;
		this.laneTarget = laneTarget;
	}

	public inline function isWasm():Bool
		return profile.kind == TargetKind.Wasm;
}
