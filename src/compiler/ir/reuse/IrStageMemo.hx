package compiler.ir.reuse;

import compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.objects.IrTypedInterfaceDispatch.IrTypedInterfaceRequest;
import compiler.ir.pipeline.IrFunctionPass.IrStageRequest;

/** What one stage made of one function in a build, and what that rested on (`IrStageMemo`). */
class IrStageEntry {
	/** The version of the function the stage was given (`IrLineage`); 0 for one the stage added. */
	public final input:Int;

	/** The facts the stage read for it, pairs of a fact and its print (`IrFacts`). */
	public final facts:Array<Int>;

	/** What the stage made of it: the function it was given when the stage left it alone. Never changed once made. */
	public final output:IrFunction;

	/** The version of `output`: the input's when the stage left it alone. */
	public final outputVersion:Int;

	/** What the stage summarized of the function for its whole-program step (`IrFunctionPass.summarize`). */
	public final summary:Int;

	/** The helpers the rewrite asked for, in order (`IrFactReader.request`); null for none. */
	public final requests:Null<Array<IrStageRequest>>;

	/** The last build its memo used it in (`IrStageMemo.keep`): the only field that changes. */
	public var used = 0;

	public function new(input:Int, facts:Array<Int>, output:IrFunction, outputVersion:Int, summary:Int,
			requests:Null<Array<IrStageRequest>>) {
		this.input = input;
		this.facts = facts;
		this.output = output;
		this.outputVersion = outputVersion;
		this.summary = summary;
		this.requests = requests;
	}
}

/**
 * One assembly stage's memo in a session: by function name, what the stage made of the function when it last ran
 * (`IrStageEntry`). An entry reused is not written again; one the stage did not use in its last run is dropped as the next run
 * starts, so a function the program lost drops out one build later.
 */
class IrStageMemo {
	final entries:Map<String, IrStageEntry> = [];

	var count = 0;
	var keptLastRun = 0;
	var kept = 0;

	/** The build this run belongs to (`IrStageMemos.build`), and the one the stage ran in before. */
	var build = 0;

	var lastRun = 0;

	public function new() {}

	/** Starts `forBuild`, once: what the stage did not use in its last run is dropped. */
	public function begin(forBuild:Int):Void {
		if (build == forBuild)
			return;
		lastRun = build;
		build = forBuild;
		keptLastRun = kept;
		kept = 0;
		if (count > keptLastRun) {
			var stale = [for (name => entry in entries) if (entry.used < lastRun) name];
			for (name in stale)
				entries.remove(name);
			count -= stale.length;
		}
	}

	/** The entry for `name` from an earlier run, or null. */
	public inline function last(name:String):Null<IrStageEntry>
		return entries.get(name);

	/** Records `entry` as this run's for `name`. */
	public function keep(name:String, entry:IrStageEntry):Void {
		var known = entries.get(name);
		if (known == null)
			count++;
		if (known != entry)
			entries.set(name, entry);
		entry.used = build;
		kept++;
	}
}
/**
 * The per-function memos of the assembly stages in a session (docs/design/QUERY_ENGINE.md, the passes in pipeline order): one
 * `IrStageMemo` per stage, the facts they read (`IrFacts`) and the versions they key on (`IrFunctionVersions`). The copies of the
 * session state share them: an entry holds only while its input version and the prints of its facts are the ones it recorded,
 * and neither is ever given twice, so what a rolled-back build left is never wrongly reused.
 */
class IrStageMemos {
	public final facts = new IrFacts();
	public final versions:IrFunctionVersions;

	/** The lineage the assembly runs keep, one at a time (`IrLineage.start`). */
	public final lineage:IrLineage;

	final stages:Map<String, IrStageMemo> = [];

	/** What each function gives the type-aware walks (`IrWalkSummary`), shared by the dispatch walk and the entry prune. */
	public final walkSummaries = new IrContributionMemo<IrWalkSummary>();

	/** The typed interface dispatchers each function calls (`IrTypedInterfaceDispatch.generate`). */
	public final interfaceRequests = new IrContributionMemo<Array<IrTypedInterfaceRequest>>();

	/** What each function needs of the runtime surface (`IrRuntimeNeeds`). */
	public final runtimeNeeds = new IrContributionMemo<compiler.ir.pipeline.IrProgramAssembler.IrRuntimeNeeds>();

	/** The method references, erased operations and type tests each function asks for (`IrGenericOwnerErasure.requestsOf`). */
	public final erasureRequests =
		new IrContributionMemo<Array<compiler.ir.passes.objects.IrGenericOwnerErasure.IrErasureRequest>>();

	/** What each function lets escape, for the closed enum tag ABI's choice (`IrTagEscapeRecord`). */
	public final tagEscapes = new IrContributionMemo<compiler.ir.passes.enums.IrClosedEnumTagAbi.IrTagEscapeRecord>();

	/** What each function lets escape or keeps in value form, for the inline enum eligibility (`IrInlineEnumUses`). */
	public final inlineEnumUses =
		new IrContributionMemo<compiler.ir.passes.enums.IrInlineEnumEligibility.IrInlineEnumUses>();

	/** The functions each function takes as closures (`IrScalarArguments`). */
	public final closureNames = new IrContributionMemo<Array<String>>();

	/** What each function's rows do with closures (`IrClosureUses`). */
	public final closureUses = new IrContributionMemo<compiler.ir.passes.scalars.IrScalarClosures.IrClosureUses>();

	/** The types naming an array or an iterator each function has (`IrValueArrayProgramRewrite`). */
	public final arrayTypes = new IrContributionMemo<Array<Int>>();

	/** The specialized enums each function names (`IrEnumRuntimeSpecializations.materialize`). */
	public final enumMentions = new IrContributionMemo<Array<String>>();

	/** The build the stages run for, counted by `startBuild`. */
	public var build(default, null) = 0;

	/**
	 * Generated helpers whose name says all they are made of (the enum dispatch's boxes, views and unboxes), by name: a build that
	 * asks for one again takes last build's, without making it. What a build did not keep is dropped when the next one starts.
	 */
	var helpers:Map<String, IrContribution<IrFunction>> = [];

	var keptHelpers:Map<String, IrContribution<IrFunction>> = [];

	/** Last build's helper `name`, or null. */
	public function helper(name:String):Null<IrFunction> {
		var known = helpers.get(name);
		return known == null ? null : known.value;
	}

	/** Keeps `fn` for the next build (`helper`). */
	public function keepHelper(fn:IrFunction):Void
		keptHelpers.set(fn.name, new IrContribution(fn, build));

	public function new(versions:IrFunctionVersions) {
		this.versions = versions;
		lineage = new IrLineage(this);
	}

	/** Starts an assembly run. */
	public function startBuild():Void {
		build++;
		helpers = keptHelpers;
		keptHelpers = [];
		walkSummaries.begin(build);
		interfaceRequests.begin(build);
		erasureRequests.begin(build);
		runtimeNeeds.begin(build);
		enumMentions.begin(build);
		tagEscapes.begin(build);
		inlineEnumUses.begin(build);
		closureNames.begin(build);
		closureUses.begin(build);
		arrayTypes.begin(build);
	}

	/** The memo of `stage`, started for this build. */
	public function stage(name:String):IrStageMemo {
		var memo = stages.get(name);
		if (memo == null) {
			memo = new IrStageMemo();
			stages.set(name, memo);
		}
		memo.begin(build);
		return memo;
	}
}

/** A function's place in the lineage: the function a name stands for in this build, and its version. */
class IrLineageCell {
	public var fn:IrFunction;
	public var version:Int;
	public var build:Int;

	/** The last settling that found the name in the program (`IrLineage.settle`). */
	public var seen = 0;

	public function new(fn:IrFunction, version:Int, build:Int) {
		this.fn = fn;
		this.version = version;
		this.build = build;
	}
}

/**
 * The version of each function of the program under assembly, from the generator's (`ModuleState.irVersions`) through each stage
 * before the encode point: a function a stage leaves alone keeps its version, one it changes takes the version its memo has for
 * what it made, or a new one. The session keeps one (`IrStageMemos.lineage`), whose cells each build updates in place; a version
 * names one function object, so a cell left from another build is never wrong.
 */
class IrLineage {
	@:processWide("a shared empty list of facts, only ever read")
	public static final NO_FACTS:Array<Int> = [];

	/** What the memo of the frozen functions a stage without a memo hands on is named after the stage (`handedOn`). */
	public static inline final SETTLED = ":settled";

	/** What a stage's memo of the functions it derives (`IrFunctionStages.derived`) is named after the stage. */
	public static inline final DERIVED = ":derived";

	/** The name the input's settling is metered and memoized under. */
	public static inline final INPUT = "assembly-input";

	public final memos:IrStageMemos;

	/** `--check-reuse`: what a contribution memo reuses is computed again and compared. */
	public var checks(default, null) = false;

	/**
	 * Past the encode point: the stages read and edit bodies, and what a memo keeps is frozen. A function a stage without a memo
	 * hands on is then not compared with last build's (no cache compares after it computes): one whose body is not frozen (made
	 * this build) takes a new version, and a frozen one that is not the function its name stood for keeps the version it had when
	 * the stage handed on the same object last build (`handedOn`), else takes a new one.
	 */
	public var bodies(default, null) = false;

	/** From here the stages read bodies (`bodies`). */
	public function enterBodies():Void
		bodies = true;

	final cells:Map<String, IrLineageCell> = [];
	var cellCount = 0;

	/** How many names stand for a function in this build. */
	var live = 0;

	var settling = 0;

	public function new(memos:IrStageMemos)
		this.memos = memos;

	/**
	 * Starts a build's lineage from the assembly's input: a generator function has its version (`generated`, 0 for a function the
	 * generator does not hold); any other one, which the frontend or the assembler makes each build (the initializers, the observable
	 * field counts, the structure printers), is settled as a stage's output (`settle`), so it keeps its identity while it is made the
	 * same. The cells of names the build does not have are dropped.
	 */
	public static function start(memos:IrStageMemos, functions:Array<IrFunction>, generated:String->Int,
			checks:Bool):IrLineage {
		memos.startBuild();
		var lineage = memos.lineage, memo = memos.stage(INPUT);
		lineage.checks = checks;
		lineage.bodies = false;
		lineage.live = 0;
		if (lineage.cellCount > functions.length * 2)
			lineage.sweep();
		for (index in 0...functions.length) {
			var fn = functions[index], version = generated(fn.name);
			if (version > 0)
				lineage.set(fn, version);
			else
				functions[index] = lineage.settleOne(memo, fn, 0);
		}
		return lineage;
	}

	/** Drops the cells no function had in the last build. */
	function sweep():Void {
		var stale = [for (name => cell in cells) if (cell.build < memos.build - 1) name];
		for (name in stale)
			cells.remove(name);
		cellCount -= stale.length;
	}

	/** The version of `fn` when it is the function its name stands for in this build; 0 otherwise. */
	public function versionOf(fn:IrFunction):Int {
		var cell = cells.get(fn.name);
		return cell != null && cell.fn == fn && cell.build == memos.build ? cell.version : 0;
	}

	/** The version of the function named `name` as the stages stand; 0 when it has none. */
	public function version(name:String):Int {
		var cell = cells.get(name);
		return cell == null || cell.build != memos.build ? 0 : cell.version;
	}

	/**
	 * The function `name` stands for as the stages stand, or null: the program's shared name index before the encode point
	 * (`IrFunctionIndex`). Within a stage that rewrites functions one by one, one it already rewrote is its rewritten form.
	 */
	public function named(name:String):Null<IrFunction> {
		var cell = cells.get(name);
		return cell == null || cell.build != memos.build ? null : cell.fn;
	}

	/** `--check-reuse`: the names that stand for a function are those of `functions`, as `pass` indexes them through `named`. */
	public function checkIndex(pass:String, functions:Array<IrFunction>):Void {
		if (functions.length != live)
			throw new compiler.core
				.InternalError('--check-reuse: $pass indexes ${functions.length} functions by name, but $live names stand for one');
		for (fn in functions)
			if (named(fn.name) == null)
				throw new compiler.core
					.InternalError('--check-reuse: $pass indexes "${fn.name}", which no name stands for');
	}

	/** Records `version` as the version of `fn`. */
	public function set(fn:IrFunction, version:Int):Void {
		var cell = cells.get(fn.name);
		if (cell == null) {
			cells.set(fn.name, new IrLineageCell(fn, version, memos.build));
			cellCount++;
			live++;
		} else {
			if (cell.build != memos.build)
				live++;
			cell.fn = fn;
			cell.version = version;
			cell.build = memos.build;
		}
	}

	/**
	 * After a stage without a memo of its own: each function it changed or added becomes what the stage made of it last build when
	 * that is the same (`IrFunctionStateEquality.same`) from the same input, and takes that one's version, else a new one. `functions`
	 * is changed in place.
	 */
	public function settle(stage:String, functions:Array<IrFunction>):Void {
		var memo:Null<IrStageMemo> = null, mark = ++settling;
		for (index in 0...functions.length) {
			var fn = functions[index], cell = cells.get(fn.name);
			if (bodies) {
				var body = fn.body;
				if (cell == null || cell.fn != fn || cell.build != memos.build || body == null || !body.frozen) {
					set(fn, body != null && body.frozen ? handedOn(stage, fn) : memos.versions.next());
					cell = cells.get(fn.name);
				}
			} else if (cell == null || cell.fn != fn || cell.build != memos.build) {
				if (memo == null)
					memo = memos.stage(stage);
				functions[index] = settleOne(memo, fn, version(fn.name));
				cell = cells.get(fn.name);
			}
			if (cell != null)
				cell.seen = mark;
		}
		// A name the stage dropped stands for nothing from here on.
		if (live > functions.length) {
			for (cell in cells)
				if (cell.build == memos.build && cell.seen != mark)
					cell.build = 0;
			live = functions.length;
		}
	}

	/**
	 * The version of `fn`, frozen, which `stage` hands on in place of the function its name stood for: the version it had when the
	 * stage handed on the same object last build (a stage that keeps what it made, as the value array rewrite's factory lowerings
	 * do), else a new one. An object is never changed once frozen, so the same object is the same function; nothing is compared.
	 */
	function handedOn(stage:String, fn:IrFunction):Int {
		var memo = memos.stage(stage + SETTLED), entry = memo.last(fn.name);
		if (entry == null || entry.output != fn)
			entry = new IrStageEntry(0, NO_FACTS, fn, memos.versions.next(), 0, null);
		memo.keep(fn.name, entry);
		return entry.outputVersion;
	}

	/** `fn`, made from the function of version `input` (0 for none), settled with `memo` and recorded. */
	public function settleOne(memo:IrStageMemo, fn:IrFunction, input:Int):IrFunction {
		var entry = memo.last(fn.name);
		if (entry == null || entry.input != input
			|| !compiler.ir.codec.IrFunctionStateEquality.same(entry.output, fn))
			entry = new IrStageEntry(input, NO_FACTS, fn, memos.versions.next(), 0, null);
		memo.keep(fn.name, entry);
		set(entry.output, entry.outputVersion);
		return entry.output;
	}
}

/** A contribution a memo keeps, with the last build that used it. */
class IrContribution<T> {
	public final value:T;
	public var used:Int;

	public function new(value:T, used:Int) {
		this.value = value;
		this.used = used;
	}
}

/**
 * What a whole-program step reads of each function, by the function's version (`IrLineage.versionOf`): a function the lineage
 * gives the same version has the same contribution, so it is not read again. A version names one function, so the versions a
 * function has at different stages are different entries. What a build did not use is dropped when the next one starts.
 */
class IrContributionMemo<T> {
	final entries:Map<Int, IrContribution<T>> = [];
	var build = 0;
	var count = 0;
	var usedLastBuild = 0;
	var used = 0;

	public function new() {}

	/** Starts `forBuild`: what the last build did not use is dropped. */
	public function begin(forBuild:Int):Void {
		var lastBuild = build;
		build = forBuild;
		usedLastBuild = used;
		used = 0;
		if (count > usedLastBuild) {
			var stale = [for (version => entry in entries) if (entry.used < lastBuild) version];
			for (version in stale)
				entries.remove(version);
			count -= stale.length;
		}
	}

	/** The contribution of the function of `version`, or null; one returned counts as used. */
	public function get(version:Int):Null<T> {
		var entry = entries.get(version);
		if (entry == null)
			return null;
		if (entry.used != build) {
			entry.used = build;
			used++;
		}
		return entry.value;
	}

	/** Keeps `value` as the contribution of the function of `version`. */
	public function keep(version:Int, value:T):Void {
		if (!entries.exists(version))
			count++;
		entries.set(version, new IrContribution(value, build));
		used++;
	}
}
