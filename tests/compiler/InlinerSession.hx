import compiler.ir.model.Ir.IrProgram;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.pipeline.TargetProfile;
import compiler.ir.reuse.IrFunctionVersions;
import compiler.ir.reuse.IrStageMemo.IrLineage;
import compiler.ir.reuse.IrStageMemo.IrStageEntry;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

/**
 * The inliner as a compile server runs it build after build: one inline cache and one set of stage memos, each program's functions
 * settled into the lineage first (`IrLineage.start`), so a function made again the same keeps its version and its entry.
 */
class InlinerSession {
	public final cache:IrInlineCache;
	public final memos:IrStageMemos;

	public function new(?cache:IrInlineCache, ?memos:IrStageMemos) {
		this.cache = cache != null ? cache : new IrInlineCache();
		this.memos = memos != null ? memos : new IrStageMemos(new IrFunctionVersions());
	}

	/** Inlines `program` as the next build. */
	public function run(program:IrProgram, ?profile:TargetProfile, ?options:compiler.CompileOptions):Array<String> {
		var lineage = IrLineage.start(memos, program.functions, _ -> 0, false);
		lineage.enterBodies();
		return IrInliner.run(program, cache, profile != null ? profile : TargetProfile.wasm, options, null, lineage);
	}

	/** The stage memo's entry for `name`, as the last build left it. */
	public function entry(name:String):Null<IrStageEntry>
		return memos.stage("inliner").last(name);

	/** A speculative build's session: a copy of the cache, the memos shared, as a candidate state shares them. */
	public function copy():InlinerSession
		return new InlinerSession(cache.copy(), memos);
}
