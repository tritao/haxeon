package compiler.ir.reuse;

import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrFunctionSlots;
import compiler.ir.pipeline.IrFunctionPass.IrStageRequest;

/** What one stage made of one function in a build, and what that rested on (`IrStageMemo`). */
@:nullSafety(Strict)
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
 * One assembly stage's memo in a session: by function slot (`IrLineage.slots`), what the stage made of the function when it last
 * ran (`IrStageEntry`). An entry reused is not written again; one the stage did not use in its last run is dropped as the next run
 * starts, so a function the program lost drops out one build later.
 */
@:nullSafety(Strict)
class IrStageMemo {
	final entries:Array<Null<IrStageEntry>> = [];

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
		if (count > keptLastRun)
			for (slot in 0...entries.length) {
				var entry = entries[slot];
				if (entry != null && entry.used < lastRun) {
					entries[slot] = null;
					count--;
				}
			}
	}

	/** The entry for the function of `slot` from an earlier run, or null. */
	public inline function last(slot:Int):Null<IrStageEntry>
		return slot < entries.length ? entries[slot] : null;

	/** Records `entry` as this run's for the function of `slot`. Inline: a stage keeps an entry for every function. */
	public inline function keep(slot:Int, entry:IrStageEntry):Void {
		if (last(slot) != entry)
			replace(slot, entry);
		entry.used = build;
		kept++;
	}

	function replace(slot:Int, entry:IrStageEntry):Void {
		if (last(slot) == null)
			count++;
		entries[slot] = entry;
	}

	/** Forgets the entry of `slot`, whose name is gone (`IrLineage.sweep`). */
	public function drop(slot:Int):Void {
		if (last(slot) != null) {
			entries[slot] = null;
			count--;
		}
	}
}

/**
 * The per-function memos of the assembly stages in a session (docs/design/QUERY_ENGINE.md, the passes in pipeline order): one
 * `IrStageMemo` per stage, the facts they read (`IrFacts`) and the versions they key on (`nextVersion`). The copies of the
 * session state share them: an entry holds only while its input version and the prints of its facts are the ones it recorded,
 * and neither is ever given twice, so what a rolled-back build left is never wrongly reused.
 */
@:nullSafety(Strict)
class IrStageMemos {
	public final facts = new IrFacts();

	/**
	 * The session's database and its kind of the functions the assembly starts from (`SessionState.irGeneration`), which the
	 * input of each run is put into (`IrLineage.start`); null for memos outside a session's database.
	 */
	public final database:Null<compiler.query.QueryDatabase>;

	public final inputs:Null<compiler.query.ComputedQueryKind<IrFunction>>;

	var lastVersion = 0;

	/** A version no function of the session had before: a version names one function object. */
	public function nextVersion():Int
		return ++lastVersion;

	/** The lineage the assembly runs keep, one at a time (`IrLineage.start`). */
	public final lineage:IrLineage;

	final stages:Map<String, IrStageMemo> = [];

	/** The contribution memos the stages registered (`contribution`), by name, each begun with every build. */
	final contributions:Map<String, IrContributionMemo<Dynamic>> = [];

	/** The session's memo of `key`, registered the first time a stage asks for it. */
	public function contribution<T>(key:IrContributionKey<T>):IrContributionMemo<T> {
		var memo = contributions.get(key.name);
		if (memo == null) {
			memo = new IrContributionMemo<Dynamic>();
			memo.begin(build);
			contributions.set(key.name, memo);
		}
		return cast memo;
	}

	/** The whole-program results the stages keep (`lastResult`), by key. */
	final results:Map<String, Dynamic> = [];

	/**
	 * The whole-program result the session keeps under `key` from the last build that kept one, or null. It holds what it was worked
	 * out from, which its stage compares with what the program gives now before it reuses it: no build is trusted to have left it.
	 */
	public function lastResult<T>(key:IrContributionKey<T>):Null<T>
		return results.get(key.name);

	/** Keeps `value` as the result under `key` (`lastResult`). */
	public function keepResult<T>(key:IrContributionKey<T>, value:T):Void
		results.set(key.name, value);

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

	public function new(?database:compiler.query.QueryDatabase, ?inputs:compiler.query.ComputedQueryKind<IrFunction>) {
		this.database = database;
		this.inputs = inputs;
		lineage = new IrLineage(this);
	}

	/** Starts an assembly run. */
	public function startBuild():Void {
		build++;
		facts.startBuild();
		helpers = keptHelpers;
		keptHelpers = [];
		for (memo in contributions)
			memo.begin(build);
	}

	/** Forgets the entries of `slots` in every stage's memo: their names are gone, and the slots are given to other names. */
	public function dropSlots(slots:Array<Int>):Void
		for (memo in stages)
			for (slot in slots)
				memo.drop(slot);

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

/**
 * The version of each function of the program under assembly, from its input (`start`) through each stage before the encode
 * point: a function a stage leaves alone keeps its version, one it changes takes the version its memo has for what it made, or a
 * new one. The session keeps one (`IrStageMemos.lineage`), whose cells, one per function slot (`slots`), each
 * build updates in place; a version names one function object, so a cell left from another build is never wrong.
 */
@:nullSafety(Strict)
class IrLineage {
	@:processWide("a shared empty list of facts, only ever read")
	public static final NO_FACTS:Array<Int> = [];

	/** What a stage's memo of the functions it derives (`IrFunctionStages.derived`) is named after the stage. */
	public static inline final DERIVED = ":derived";

	/** The name the input's settling is metered under. */
	public static inline final INPUT = "assembly-input";

	public final memos:IrStageMemos;

	/** The slots of the function names, which the cells and the stage memos are indexed by. */
	public final slots = new IrFunctionSlots();

	/** `--check-reuse`: what a contribution memo reuses is computed again and compared. */
	public var checks(default, null) = false;

	/**
	 * Past the encode point: the stages read and edit bodies, and what a memo keeps is frozen. A function a stage without a memo
	 * hands on in place of the one its name stood for is then not compared with last build's (no cache compares after it
	 * computes): it takes a new version.
	 */
	public var bodies(default, null) = false;

	/** From here the stages read bodies (`bodies`). */
	public function enterBodies():Void
		bodies = true;

	// The cells, by slot: the function the name stands for in build `cellBuilds`, its version, and the last settling that marked
	// the name as in the program (`endSettling`).
	final cellFunctions:Array<Null<IrFunction>> = [];
	final cellVersions:Array<Int> = [];
	final cellBuilds:Array<Int> = [];
	final cellSeen:Array<Int> = [];
	var cellCount = 0;

	/** By slot, the function the last build's input had and its version (`inputVersion`). */
	final inputFunctions:Array<Null<IrFunction>> = [];

	final inputVersions:Array<Int> = [];

	/** How many names stand for a function in this build. */
	var live = 0;

	/** How many times a cell changed: while it does not move, every function that stood for its name still does. */
	public var writes(default, null) = 0;

	var settling = 0;

	public function new(memos:IrStageMemos)
		this.memos = memos;

	/**
	 * Starts a build's lineage from the assembly's input. Each function is put into the session's kind of the input functions
	 * (`IrStageMemos.inputs`), which keeps last build's object for one made again the same, so a function keeps its version
	 * while it is the same object (`inputVersion`). The cells of names the build does not have are dropped.
	 */
	public static function start(memos:IrStageMemos, functions:Array<IrFunction>, checks:Bool):IrLineage {
		memos.startBuild();
		var lineage = memos.lineage, database = memos.database, inputs = memos.inputs;
		lineage.checks = checks;
		lineage.bodies = false;
		lineage.live = 0;
		if (lineage.cellCount > functions.length * 2)
			lineage.sweep();
		for (index in 0...functions.length) {
			var fn = functions[index];
			// Most of the input is the function the kind holds: that is checked typed, as the kind's own check is dynamic.
			if (database != null && inputs != null && inputs.kept(fn.symbol.id) != fn)
				functions[index] = fn = inputs.put(database, fn.symbol.id, fn);
			var slot = lineage.slots.of(fn);
			lineage.setAt(slot, fn, lineage.inputVersion(slot, fn));
		}
		return lineage;
	}

	/** The version of input `fn`, whose slot is `slot`: last build's input's when `fn` is that function, else a new one. */
	function inputVersion(slot:Int, fn:IrFunction):Int {
		if (slot < inputFunctions.length && inputFunctions[slot] == fn)
			return inputVersions[slot];
		var version = memos.nextVersion();
		inputFunctions[slot] = fn;
		inputVersions[slot] = version;
		return version;
	}

	/** Frees the slots no function had in the last build, with their cells and their entries in the stage memos. */
	function sweep():Void {
		var stale:Array<Int> = [], before = memos.build - 1;
		for (slot in 0...slots.count)
			if (slots.used(slot) && (slot >= cellBuilds.length || cellBuilds[slot] < before)) {
				stale.push(slot);
				if (slot < inputFunctions.length)
					inputFunctions[slot] = null;
				if (slot < cellFunctions.length && cellFunctions[slot] != null) {
					cellFunctions[slot] = null;
					cellBuilds[slot] = 0;
					cellCount--;
				}
			}
		memos.dropSlots(stale);
		slots.free(stale);
	}

	/** The version of the function of `slot` as the stages stand; 0 when it has none. */
	public inline function versionAt(slot:Int):Int
		return slot < cellBuilds.length && cellBuilds[slot] == memos.build ? cellVersions[slot] : 0;

	/** The version of `fn` when it is the function its name stands for in this build; 0 otherwise. */
	public function versionOf(fn:IrFunction):Int {
		var slot = slots.known(fn);
		return slot >= 0 && slot < cellFunctions.length && cellFunctions[slot] == fn ? versionAt(slot) : 0;
	}

	/** The version of the function named `name` as the stages stand; 0 when it has none. */
	public function version(name:String):Int {
		var slot = slots.knownNamed(name);
		return slot < 0 ? 0 : versionAt(slot);
	}

	/**
	 * The function `name` stands for as the stages stand, or null: the program's shared name index before the encode point
	 * (`IrFunctionIndex`). Within a stage that rewrites functions one by one, one it already rewrote is its rewritten form.
	 */
	public function named(name:String):Null<IrFunction> {
		var slot = slots.knownNamed(name);
		return slot < 0 || !standsAt(slot) ? null : cellFunctions[slot];
	}

	/** Whether a function stands for the name of `slot` in this build. */
	inline function standsAt(slot:Int):Bool
		return slot < cellBuilds.length && cellBuilds[slot] == memos.build;

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
	public function set(fn:IrFunction, version:Int):Void
		setAt(slots.of(fn), fn, version);

	/** Records `version` as the version of `fn`, whose slot is `slot`. */
	public function setAt(slot:Int, fn:IrFunction, version:Int):Void {
		if (slot >= cellFunctions.length || cellFunctions[slot] == null) {
			cellCount++;
			live++;
		} else if (cellBuilds[slot] != memos.build)
			live++;
		cellFunctions[slot] = fn;
		cellVersions[slot] = version;
		cellBuilds[slot] = memos.build;
		writes++;
		if (slot >= cellSeen.length)
			cellSeen[slot] = 0;
	}

	/**
	 * After a stage without a memo of its own: each function it changed or added becomes what the stage made of it last build when
	 * that is the same (`IrFunctionStateEquality.same`) from the same input, and takes that one's version, else a new one. `functions`
	 * is changed in place.
	 */
	public function settle(stage:String, functions:Array<IrFunction>):Void {
		for (index in 0...functions.length) {
			var fn = functions[index], settled = settleEntry(stage, slots.of(fn), fn);
			if (settled != fn)
				functions[index] = settled;
		}
		endSettling(functions);
	}

	/**
	 * The function of `slot` at its place in a list being settled (`settle`, which a caller that knows the slots does entry by
	 * entry, then `endSettling`): `fn` when it already stands for its name, else `fn` settled as `settle` does. Inline: every
	 * stage settles every function.
	 */
	public inline function settleEntry(stage:String, slot:Int, fn:IrFunction):IrFunction {
		var stands = slot < cellFunctions.length && cellFunctions[slot] == fn && cellBuilds[slot] == memos.build;
		return stands ? fn : settleChanged(stage, slot, fn);
	}

	function settleChanged(stage:String, slot:Int, fn:IrFunction):IrFunction {
		if (!bodies)
			return settleAt(memos.stage(stage), slot, fn, versionAt(slot));
		setAt(slot, fn, memos.nextVersion());
		return fn;
	}

	/**
	 * Ends settling `functions`: a name they do not have stands for nothing from here on. Each of them stands for its name, so
	 * only more names than functions can mean one to drop, and only then are the names they have marked.
	 */
	public function endSettling(functions:Array<IrFunction>):Void {
		if (live <= functions.length)
			return;
		var mark = ++settling, build = memos.build;
		for (fn in functions)
			cellSeen[slots.of(fn)] = mark;
		for (slot in 0...cellFunctions.length)
			if (cellBuilds[slot] == build && cellSeen[slot] != mark) {
				cellBuilds[slot] = 0;
				writes++;
			}
		live = functions.length;
	}

	function settleAt(memo:IrStageMemo, slot:Int, fn:IrFunction, input:Int):IrFunction {
		var entry = memo.last(slot);
		if (entry == null || entry.input != input
			|| !compiler.ir.codec.IrFunctionStateEquality.same(entry.output, fn))
			entry = new IrStageEntry(input, NO_FACTS, fn, memos.nextVersion(), 0, null);
		memo.keep(slot, entry);
		setAt(slot, entry.output, entry.outputVersion);
		return entry.output;
	}
}

/**
 * The name a stage registers a contribution memo under (`IrStageMemos.contribution`), typed with what the memo keeps: a stage
 * declares its key once, so no two stages share a memo by accident.
 */
@:nullSafety(Strict)
class IrContributionKey<T> {
	public final name:String;

	public function new(name:String)
		this.name = name;
}

/** A contribution a memo keeps, with the last build that used it. */
@:nullSafety(Strict)
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
@:nullSafety(Strict)
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
