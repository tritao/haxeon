import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.pipeline.TargetProfile;
import compiler.ir.reuse.IrStageMemo.IrLineage;
import compiler.ir.reuse.IrStageMemo.IrStageEntry;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;

/**
 * The inliner as a compile server runs it build after build: one inline cache and one set of stage memos, each program's functions
 * put into the session's input kind first (`IrLineage.start`), so a function made again the same keeps its object, its version and
 * its entry.
 */
class InlinerSession {
	public final cache:IrInlineCache;
	public final memos:IrStageMemos;

	public function new(?cache:IrInlineCache, ?memos:IrStageMemos) {
		this.cache = cache != null ? cache : new IrInlineCache();
		if (memos == null) {
			var database = new QueryDatabase();
			memos = new IrStageMemos(database,
				database.register(new ComputedQueryKind<IrFunction>("ir-generation", IrFunctionStateEquality.same)));
		}
		this.memos = memos;
	}

	/** Inlines `program` as the next build. */
	public function run(program:IrProgram, ?profile:TargetProfile, ?options:compiler.CompileOptions):Array<String> {
		var database = memos.database;
		if (database != null)
			database.newRevision();
		var lineage = IrLineage.start(memos, program.functions, false);
		lineage.enterBodies();
		return IrInliner.run(program, cache, profile != null ? profile : TargetProfile.wasm, options, null, lineage);
	}

	/** The stage memo's entry for `name`, as the last build left it. */
	public function entry(name:String):Null<IrStageEntry>
		return memos.stage("inliner").last(memos.lineage.slots.named(name));

	/** A speculative build's session: a copy of the cache, the memos shared, as a candidate state shares them. */
	public function copy():InlinerSession
		return new InlinerSession(cache.copy(), memos);
}
