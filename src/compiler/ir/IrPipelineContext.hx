package compiler.ir;

import compiler.ir.Ir.IrObject;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.IrStageMemo.IrLineage;
import compiler.ir.IrStageMemo.IrStageMemos;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.TargetProfile.TargetKind;

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

	/** The session's per-function memos of the stages before the encode point; null in a compile that keeps none. */
	public var stageMemos:Null<IrStageMemos> = null;

	/** The generator's version of each function it holds (`ModuleState.irVersions`), 0 for another; with `stageMemos`. */
	public var generatedVersion:Null<String->Int> = null;

	/** The versions of the functions as the stages before the encode point stand, in a session (`IrLineage`); null elsewhere. */
	public var lineage:Null<IrLineage> = null;

	/** The roots of the early prune: the entry function, the static initializers and the exported functions. */
	public var pruneRoots:Array<String> = [];

	// Target lowering (`IrPipeline.target`).
	public var livePatching:Bool = false;
	public var developmentMetadata:Bool = false;
	public var reflectable:Null<Array<String>> = null;
	public var inlineCache:Null<IrInlineCache> = null;
	public var instrumentScope:Null<IrInstrumentation.IrInstrumentationScope> = null;
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

	/** The build prunes the program from its entry (`IrEntryPrune.run`). */
	public var pruneFromEntry:Bool = false;

	/** What the prune removed; empty without it. */
	public var pruned:Map<String, Bool> = [];

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
