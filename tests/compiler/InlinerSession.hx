import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.pipeline.TargetProfile;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;

/**
 * The inliner as a compile server runs it build after build: one inline cache and one set of stage memos, each program's functions
 * put into the session's input kind first (`IrStageMemos.startBuild`), so a function made again the same keeps its object, its version and
 * its memo.
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
		memos.database.newRevision();
		memos.startBuild(program.functions, false);
		memos.bodies = true;
		return IrInliner.run(program, cache, profile != null ? profile : TargetProfile.wasm, options, null, memos);
	}

	/** The revision `name`'s memo was last computed at, 0 for none: the same after a build that held it. */
	public function computedIn(name:String):Int {
		var forms = memos.inliner().forms, slot = forms.slotOf(IrSymbol.of(name).functionKey());
		return slot < 0 || forms.verifiedIn(slot) == 0 ? 0 : forms.computedIn(slot);
	}

	/** The cleaned form the memo of `name` keeps, as the last build left it. */
	public function cleaned(name:String):Null<IrFunction> {
		var forms = memos.inliner().forms, slot = forms.slotOf(IrSymbol.of(name).functionKey());
		return slot < 0 ? null : memos.inliner().cleanedOf(slot);
	}

	/** A speculative build's session: a copy of the cache, the memos shared, as a candidate state shares them. */
	public function copy():InlinerSession
		return new InlinerSession(cache.copy(), memos);
}
