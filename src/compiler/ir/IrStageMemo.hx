package compiler.ir;

import compiler.ir.Ir.IrType;

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
	public final requests:Null<Array<IrType>>;

	/** The last build its memo used it in (`IrStageMemo.keep`): the only field that changes. */
	public var used = 0;

	public function new(input:Int, facts:Array<Int>, output:IrFunction, outputVersion:Int, summary:Int,
			requests:Null<Array<IrType>>) {
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

	/** The build the stages run for, counted by `startBuild`. */
	public var build(default, null) = 0;

	public function new(versions:IrFunctionVersions) {
		this.versions = versions;
		lineage = new IrLineage(this);
	}

	/** Starts an assembly run. */
	public function startBuild():Void
		build++;

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

	/** The name the input's settling is metered and memoized under. */
	public static inline final INPUT = "assembly-input";

	public final memos:IrStageMemos;

	final cells:Map<String, IrLineageCell> = [];
	var cellCount = 0;

	public function new(memos:IrStageMemos)
		this.memos = memos;

	/**
	 * Starts a build's lineage from the assembly's input: a generator function has its version (`generated`, 0 for a function the
	 * generator does not hold); any other one, which the frontend or the assembler makes each build (the initializers, the observable
	 * field counts, the structure printers), is settled as a stage's output (`settle`), so it keeps its identity while it is made the
	 * same. The cells of names the build does not have are dropped.
	 */
	public static function start(memos:IrStageMemos, functions:Array<IrFunction>, generated:String->Int):IrLineage {
		memos.startBuild();
		var lineage = memos.lineage, memo = memos.stage(INPUT);
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

	/** The version of the function named `name` as the stages stand; 0 when it has none. */
	public function version(name:String):Int {
		var cell = cells.get(name);
		return cell == null || cell.build != memos.build ? 0 : cell.version;
	}

	/** Records `version` as the version of `fn`. */
	public function set(fn:IrFunction, version:Int):Void {
		var cell = cells.get(fn.name);
		if (cell == null) {
			cells.set(fn.name, new IrLineageCell(fn, version, memos.build));
			cellCount++;
		} else {
			cell.fn = fn;
			cell.version = version;
			cell.build = memos.build;
		}
	}

	/** Whether `fn` is the function its name stands for in this build. */
	inline function current(fn:IrFunction):Bool {
		var cell = cells.get(fn.name);
		return cell != null && cell.fn == fn && cell.build == memos.build;
	}

	/**
	 * After a stage without a memo of its own: each function it changed or added becomes what the stage made of it last build when
	 * that is the same (`IrFunctionStateEquality.same`) from the same input, and takes that one's version, else a new one. `functions`
	 * is changed in place.
	 */
	public function settle(stage:String, functions:Array<IrFunction>):Void {
		var memo:Null<IrStageMemo> = null;
		for (index in 0...functions.length) {
			var fn = functions[index];
			if (current(fn))
				continue;
			if (memo == null)
				memo = memos.stage(stage);
			functions[index] = settleOne(memo, fn, version(fn.name));
		}
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
