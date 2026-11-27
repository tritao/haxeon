package compiler.ir.reuse;

import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.IrFunctionPass.IrStageRequest;

/**
 * The reuse state of the IR stages in a session (docs/design/QUERY_ENGINE.md, the stage driver): what each per-function stage
 * made of each function, as kinds of the session's query database (`IrStageQueries`), and the facts their rewrites read
 * (`IrStageFacts`), with the answers verification's facts were worked out from (`IrVerifyAnswers`); the inliner's memo
 * (`IrInlineQueries`); the whole-program walks and steps (`IrWalkMemo`) and summaries
 * (`IrContributionSummary`); and, until they move onto the database too, the contribution memos. The copies of the session state
 * share it: a memo holds only while what it was made from is the same object and what it read has not changed, so what a
 * rolled-back build left is never wrongly reused.
 */
@:nullSafety(Strict)
class IrStageMemos {
	/** The session's database, and its kind of the functions the assembly starts from (`SessionState.irGeneration`). */
	public final database:compiler.query.QueryDatabase;

	public final inputs:compiler.query.ComputedQueryKind<IrFunction>;

	/** The facts the per-function stages and the inliner read, a kind of `database`. */
	public final stageFacts:IrStageFacts;

	/** `--check-reuse` in the build under way: what a memo reuses is computed again and compared. */
	public var checks(default, null) = false;

	/**
	 * Past the encode point: the stages read and edit bodies, so what they make is frozen, as the stages after them edit copies, and
	 * never compared with last build's (`IrFunctionStages`).
	 */
	public var bodies = false;

	/** The build the stages run for, counted by `startBuild`. */
	public var build(default, null) = 0;

	final queries:Map<String, IrStageQueries> = [];

	/** The inliner's memo, registered the first time the stage runs (`inliner`). */
	var inlineQueries:Null<compiler.ir.passes.inlining.IrInliner.IrInlineQueries> = null;

	/** The answers verification's facts were worked out from (`IrVerifyStage`). */
	public final verifyAnswers = new compiler.ir.verify.IrVerifyStage.IrVerifyAnswers();

	/**
	 * Generated helpers whose name says all they are made of (the enum dispatch's boxes, views and unboxes), by the symbol of the
	 * name: a build that asks for one again takes last build's, without making it. What a build did not keep is swept with it.
	 */
	var helpers:Null<compiler.query.ComputedQueryKind<IrFunction>> = null;

	/** The whole-program walks and steps registered (`walk`, `step`), by name. */
	final walks:Map<String, IrWalkMemo<Dynamic, Dynamic>> = [];

	/** The walks that follow edges (`walk`), which share the summary of a function they are given as the same object. */
	final edgeWalks:Array<IrWalkMemo<compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary, Dynamic>> = [];

	/** The contribution summaries the steps registered (`summary`), by name. */
	final summaries:Map<String, IrContributionSummary<Dynamic>> = [];

	/** The contribution memos the stages registered (`contribution`), by name, each begun with every build. */
	final contributions:Map<String, IrContributionMemo<Dynamic>> = [];


	public function new(database:compiler.query.QueryDatabase, inputs:compiler.query.ComputedQueryKind<IrFunction>) {
		this.database = database;
		this.inputs = inputs;
		stageFacts = database.register(new IrStageFacts());
	}

	/**
	 * Starts an assembly run on `functions`, its input: each is put into the session's kind of the input functions, which keeps last
	 * build's object for one made again the same, so the stages find the object they made their memos from. `functions` is changed
	 * in place.
	 */
	public function startBuild(functions:Array<IrFunction>, checks:Bool):Void {
		build++;
		bodies = false;
		this.checks = checks;
		for (memo in contributions)
			memo.begin(build);
		for (index in 0...functions.length) {
			var fn = functions[index], kept = inputs.put(database, fn.symbol.id, fn);
			if (kept != fn)
				functions[index] = kept;
		}
	}

	/**
	 * The queries of the stage `name`: before the encode point a function made again the same is the one kept (`same`), past it
	 * every function a stage makes is new (`bodies`), as the stages there edit bodies.
	 */
	public function stage(name:String, bodies:Bool):IrStageQueries {
		var known = queries.get(name);
		if (known == null) {
			known = new IrStageQueries(database, name,
				bodies ? sameObject : compiler.ir.codec.IrFunctionStateEquality.same);
			queries.set(name, known);
		}
		return known;
	}

	static function sameObject(left:IrFunction, right:IrFunction):Bool
		return left == right;

	public static function functionName(key:Int):String
		return compiler.ir.model.IrSymbol.ofFunctionKey(key).name;

	/** The kind of what the stages without a memo made (`settle`), each stage a part of it: they make few functions. */
	static inline final SETTLED = "ir-settled";

	/**
	 * After `name`, a stage before the encode point that keeps no memo of its own: each function in `functions` made since
	 * `since` (`IrFunction.versionsGiven`) becomes what the stage made of its name last build when that is the same, so the stages
	 * after it find the object they made their memos from. `functions` is changed in place.
	 */
	public function settle(name:String, functions:Array<IrFunction>, since:Int):Void {
		var settled = stage(SETTLED, false), kind = settled.functions;
		for (index in 0...functions.length) {
			var fn = functions[index];
			if (fn.version > since) {
				var kept = kind.put(database, settled.sharedKey(name, fn.symbol.functionKey()), fn);
				if (kept != fn)
					functions[index] = kept;
			}
		}
	}

	/** The inliner's memo (`IrInlineQueries`), registered the first time the stage asks for it. */
	public function inliner():compiler.ir.passes.inlining.IrInliner.IrInlineQueries {
		var known = inlineQueries;
		if (known == null)
			inlineQueries = known = new compiler.ir.passes.inlining.IrInliner.IrInlineQueries(database);
		return known;
	}

	/**
	 * The session's walk `name` (`IrWalkMemo`), which follows edges (`IrWalkSummary`) or reads no summary, registered the first time
	 * a step asks for it.
	 */
	public function walk<R>(name:String):IrWalkMemo<compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary, R> {
		var known = walks.get(name);
		if (known != null)
			return cast known;
		var made = database.register(new IrWalkMemo<compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary, Dynamic>(name,
			compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary.same, edgeWalks));
		edgeWalks.push(made);
		walks.set(name, cast made);
		return cast made;
	}

	/**
	 * The session's whole-program step `name` (`IrWalkMemo`), which reads a summary `S` of each function of its own, compared by
	 * `same`; registered the first time the step asks for it.
	 */
	public function step<S, R>(name:String, same:(S, S) -> Bool):IrWalkMemo<S, R> {
		var known = walks.get(name);
		if (known != null)
			return cast known;
		var made = database.register(new IrWalkMemo<S, Dynamic>(name, same, null));
		walks.set(name, cast made);
		return cast made;
	}

	/** The session's contribution summary `name` (`IrContributionSummary`), registered the first time a step asks for it. */
	public function summary<T>(name:String):IrContributionSummary<T> {
		var known = summaries.get(name);
		if (known == null) {
			known = new IrContributionSummary<Dynamic>(database.register(new compiler.query.QuerySummary(name)));
			summaries.set(name, known);
		}
		return cast known;
	}

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

	/** What helpers are named by, by the id of the type they are made for (`typeEncoding`), swept with the build. */
	var typeEncodings:Null<compiler.query.ComputedQueryKind<String>> = null;

	/**
	 * What `encode` makes of `type` for the helpers named by it (`IrEnumDynamicDispatch`): kept across builds by the type's id
	 * (`IrTypeIds`), as it is worked out from the type alone.
	 */
	public function typeEncoding(type:compiler.ir.model.Ir.IrType, encode:compiler.ir.model.Ir.IrType->String):String {
		var kind = typeEncodings;
		if (kind == null)
			typeEncodings = kind = database.register(new compiler.query.ComputedQueryKind<String>("ir-type-encodings",
				(left, right) -> left == right));
		var id = compiler.ir.model.IrTypeIds.id(type), known = kind.kept(id);
		return kind.put(database, id, known == null ? encode(type) : known);
	}

	/** The lanes of each enum's cases (`IrInlineEnumLayout.lanesOf`), by the configuration they are laid out in. */
	final laneKinds:Map<String, compiler.query.ComputedQueryKind<compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumLanes>>
		= [];

	/**
	 * The kind of the lanes `IrInlineEnumLayout` lays out in the configuration `name` (pointer width, target, canonical), by the
	 * id of the enum's type: they are a function of the enums and value objects alone, so a build takes last build's where the
	 * objects they read are the same. Swept with the build.
	 */
	public function inlineEnumLanes(name:String):compiler.query
		.ComputedQueryKind<compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumLanes> {
		var known = laneKinds.get(name);
		if (known == null) {
			known = database.register(new compiler.query
				.ComputedQueryKind<compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumLanes>("ir-inline-enum-lanes "
				+ name, (left, right) -> left == right));
			laneKinds.set(name, known);
		}
		return known;
	}

	/** Last build's helper `name`, or null. */
	public function helper(name:String):Null<IrFunction> {
		var kind = helpers;
		return kind == null ? null : kind.kept(compiler.ir.model.IrSymbol.of(name).functionKey());
	}

	/** Keeps `fn` for the next build (`helper`). */
	public function keepHelper(fn:IrFunction):Void {
		var kind = helpers;
		if (kind == null)
			// A helper made again is kept as made: whether it is the same is the stage's to settle, not the memo's.
			helpers = kind = database.register(new compiler.query.ComputedQueryKind<IrFunction>("ir-helpers",
				sameObject, null,
				functionName));
		kind.put(database, fn.symbol.functionKey(), fn);
	}

	/** Lets go of every memo, for a compile that keeps no session: their values would keep the functions alive. */
	public function clear():Void {
		for (stage in queries)
			stage.clear();
		stageFacts.clearReaders();
		var kind = helpers;
		if (kind != null)
			kind.clear();
		var encodings = typeEncodings;
		if (encodings != null)
			encodings.clear();
		for (lanes in laneKinds)
			lanes.clear();
		var inliner = inlineQueries;
		if (inliner != null)
			inliner.clear();
		verifyAnswers.clear();
		summaries.clear();
		for (walk in walks)
			walk.clear();
		contributions.clear();
	}
}

/**
 * What one per-function stage made of each function, by its name's number (`IrSymbol.functionKey`, `IrFunctionStages.run`): the
 * memo of the rewrite, a kind of the session's database whose reads are the facts it read (`IrStageFacts`); the version of the
 * function it was made from (`IrFunction.version`), so a memo holds only while the stage is given that same object; the stage's
 * summary of it; and the helpers the rewrite asked for. Like the kind's own, the columns are by the kind's slot of the key
 * (`ComputedQueryKind.slotOf`) and as long as its, and those most stages leave empty (the summaries, the visits, the requests) are
 * empty until a slot has one.
 */
@:nullSafety(Strict)
class IrStageQueries {
	public final functions:compiler.query.ComputedQueryKind<IrFunction>;

	/** By slot, the version of the function the memo was made from, `FROM_NAME` for a helper made from its name; 0 for none. */
	var inputs:Array<Int> = [];

	/** By slot, the stage's summary of the function the memo was made from, when it is not 0. */
	var summaries:Array<Int> = [];

	/** By slot, whether the rewrite asked for helpers, which `requests` holds. */
	var asks:Array<Int> = [];

	var requests:Map<Int, Array<IrStageRequest>> = [];

	/**
	 * By slot, the run of the stage that found a fact its memo read changed (`IrStageFacts.markReaders`), or `ALWAYS` for a memo
	 * that read more than facts: such a key is verified when the stage runs; any other whose memo was verified in the stage's last
	 * run is taken as it is (`unchanged`), so a held key costs no verification of each fact it read.
	 */
	var visit:Array<Int> = [];

	static inline final ALWAYS = -1;

	/**
	 * A stage that runs once per part of the program (once per value array element type, `IrValueArrayProgramRewrite`) keys each
	 * function of each part apart, so that one kind holds every part and the count of parts has no limit: by part, the key of each
	 * function by its name's number, plus one (`partKey`); and by key, the name's number. A kind the stages share, of the few
	 * functions each derives or adds (`sharedKey`), keeps a part's keys in a map, not in an array as long as the names.
	 */
	final parts:Map<String, Array<Int>> = [];

	final sharedParts:Map<String, Map<Int, Int>> = [];

	var functionsByKey:Array<Int> = [];

	public function new(database:compiler.query.QueryDatabase, name:String, same:(IrFunction, IrFunction) -> Bool) {
		functions = database.register(new compiler.query.ComputedQueryKind<IrFunction>(name, same, null,
			key -> IrStageMemos.functionName(functionsByKey.length > 0 ? functionsByKey[key] : key)));
	}

	/** The keys of the functions of part `name` (`partKey`). */
	public function part(name:String):Array<Int> {
		var known = parts.get(name);
		if (known == null)
			parts.set(name, known = []);
		return known;
	}

	/** The key of the function whose name's number is `named` in the part whose keys are `keys` (`part`). */
	public inline function partKey(keys:Array<Int>, named:Int):Int
		return named < keys.length && keys[named] != 0 ? keys[named] - 1 : givePartKey(keys, named);

	function givePartKey(keys:Array<Int>, named:Int):Int {
		var key = functionsByKey.length;
		functionsByKey.push(named);
		if (named >= keys.length)
			compiler.query.QueryKind.QueryRead.extend(keys, named + 1 + (named >> 1));
		keys[named] = key + 1;
		return key;
	}

	/** The key of the function whose name's number is `named` in part `name` of a kind the stages share. */
	public function sharedKey(name:String, named:Int):Int {
		var keys = sharedParts.get(name);
		if (keys == null)
			sharedParts.set(name, keys = []);
		var known = keys.get(named);
		if (known != null)
			return known;
		var key = functionsByKey.length;
		functionsByKey.push(named);
		keys.set(named, key);
		return key;
	}

	/** Whether `fn` is what the stage's memo holds for its name in the part whose keys are `keys` (`part`), or with no part. */
	public function keeps(keys:Null<Array<Int>>, fn:IrFunction):Bool {
		var named = fn.symbol.functionKey(), key = keys == null ? named : named < keys.length ? keys[named] - 1 : -1;
		return key >= 0 && functions.kept(key) == fn;
	}

	/** The input of a function made from nothing but its name, such as a helper its name describes (`made`). */
	public static inline final FROM_NAME = -1;

	/** Whether the memo in `slot` was made from the input of version `input`: it holds while nothing it read changed (`current`). */
	public inline function madeFrom(slot:Int, input:Int):Bool
		return slot < inputs.length && inputs[slot] == input && input != 0;

	/**
	 * The stage's summary of `fn`, whose slot is `slot`: the one kept when the memo was made from `fn`, else `summarize`'s, which
	 * `made` keeps. With `checks` a kept one is compared with `summarize`'s.
	 */
	public function summary(slot:Int, fn:IrFunction, pass:compiler.ir.pipeline.IrFunctionPass, checks:Bool,
			stage:String):Int {
		if (madeFrom(slot, fn.version)) {
			var kept = slot < summaries.length ? summaries[slot] : 0;
			if (checks && pass.summarize(fn) != kept)
				throw new compiler.core
					.InternalError('--check-reuse: stage $stage reused the summary of ${fn.name}, which differs from what it summarizes now');
			return kept;
		}
		return pass.summarize(fn);
	}

	/** Records that the memo in `slot` was made from the input of version `input`, summarized as `summary`, asking for `asked`. */
	public function made(slot:Int, input:Int, summary:Int, asked:Null<Array<IrStageRequest>>):Void {
		if (slot >= inputs.length)
			compiler.query.QueryKind.QueryRead.extend(inputs, functions.capacity());
		inputs[slot] = input;
		if (summary != 0) {
			if (slot >= summaries.length)
				compiler.query.QueryKind.QueryRead.extend(summaries, functions.capacity());
			summaries[slot] = summary;
		} else if (slot < summaries.length)
			summaries[slot] = 0;
		if (asked != null) {
			if (slot >= asks.length)
				compiler.query.QueryKind.QueryRead.extend(asks, functions.capacity());
			asks[slot] = 1;
			requests.set(slot, asked);
		} else if (slot < asks.length && asks[slot] != 0) {
			asks[slot] = 0;
			requests.remove(slot);
		}
	}

	/** Marks the memo in `slot` as one that read a fact that changed in `run` (`IrStageFacts.markReaders`). */
	public inline function changed(slot:Int, run:Int):Void
		if (slot >= visit.length || visit[slot] != ALWAYS)
			mark(slot, run);

	/** Whether no fact the memo in `slot` read changed in `run`, and it read nothing else. */
	public inline function unchanged(slot:Int, run:Int):Bool
		return slot >= visit.length || visit[slot] != run && visit[slot] != ALWAYS;

	function mark(slot:Int, run:Int):Void {
		if (slot >= visit.length)
			compiler.query.QueryKind.QueryRead.extend(visit, functions.capacity());
		visit[slot] = run;
	}

	/** Records, of the memo in `slot` just computed (`made`), that it read each fact it read (`IrStageFacts.addReader`). */
	public function readersOf(slot:Int, facts:IrStageFacts):Void {
		var kind = functions, only = true, index = facts.index;
		for (position in 0...kind.readsMade(slot)) {
			var read = kind.readMade(slot, position);
			if (compiler.query.QueryKind.QueryRead.kind(read) == index)
				facts.addReader(compiler.query.QueryKind.QueryRead.key(read), slot);
			else
				only = false;
		}
		if (!only)
			mark(slot, ALWAYS);
		else if (slot < visit.length)
			visit[slot] = 0;
	}

	/** Asks `pass` again for the helpers the memo in `slot` asked for, in order. */
	public inline function replay(slot:Int, pass:compiler.ir.pipeline.IrFunctionPass):Void
		if (slot < asks.length && asks[slot] != 0)
			replayAt(slot, pass);

	function replayAt(slot:Int, pass:compiler.ir.pipeline.IrFunctionPass):Void {
		var asked = requests.get(slot);
		if (asked != null)
			for (request in asked)
				pass.request(request.kind, request.type, request.name);
	}

	/** The helpers the memo in `slot` asked for, or null. */
	public function asked(slot:Int):Null<Array<IrStageRequest>>
		return slot < asks.length && asks[slot] != 0 ? requests.get(slot) : null;

	/** Lets go of every memo (`IrStageMemos.clear`). */
	public function clear():Void {
		functions.clear();
		inputs = [];
		summaries = [];
		visit = [];
		asks = [];
		requests = [];
		parts.clear();
		sharedParts.clear();
		functionsByKey = [];
	}
}

/**
 * What a whole-program step reads of each function, as a summary of the session's database (`QuerySummary`): each function, by its
 * name's number, contributes the items it names (the dispatchers it calls, the enums it mentions), each interned to a key by its
 * text, and the step reads the items some function names (`collect`). A function given as the same object as last run keeps its
 * contribution without being read (`QuerySummary.holdsFrom`, by `IrFunction.version`), so a run costs a compare per function and the
 * reading of those that changed. A step that runs at two places in the pipeline has a summary for each, as their functions differ.
 */
@:nullSafety(Strict)
class IrContributionSummary<T> {
	final keys:compiler.query.QuerySummary;

	/** The items' keys by text, and the items by key: a key is never given to another item. */
	final ids:Map<String, Int> = [];

	final items:Array<T> = [];

	/** The contribution of every function that names nothing, most of them: one array, not one each. */
	final none:Array<Int> = [];

	public function new(keys:compiler.query.QuerySummary)
		this.keys = keys;

	/**
	 * The items some function of `functions` names, each once, in the order of their keys: `read` gives what one function names, in
	 * the order it names them, and `text` an item's identity. With `checks` a kept contribution is read again and compared. The
	 * order is not the program's, so a caller orders what it makes of them itself.
	 */
	public function collect(database:compiler.query.QueryDatabase, functions:Array<IrFunction>,
			read:IrFunction->Array<T>,
			text:T->String, checks:Bool, what:String):Array<T> {
		var summary = keys;
		summary.open(database);
		for (fn in functions) {
			var key = fn.symbol.functionKey();
			if (summary.holdsFrom(database, key, fn.version)) {
				if (checks && !sameKeys(summary.contribution(key), keysOf(read(fn), text)))
					throw new compiler.core
						.InternalError('--check-reuse: the $what reused for ${fn.name} differ from its code');
				continue;
			}
			summary.contribute(database, key, keysOf(read(fn), text), fn.version);
		}
		summary.close(database);
		return [for (key in summary.keys(database)) items[key]];
	}

	function keysOf(named:Array<T>, text:T->String):Array<Int>
		return named.length == 0 ? none : [for (item in named) {
			var identity = text(item), known = ids.get(identity);
			if (known == null) {
				known = items.length;
				items.push(item);
				ids.set(identity, known);
			}
			known;
		}];

	static function sameKeys(left:Null<Array<Int>>, right:Array<Int>):Bool {
		if (left == null || left.length != right.length)
			return false;
		for (index in 0...right.length)
			if (left[index] != right[index])
				return false;
		return true;
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
 * What a whole-program step reads of each function, by the function's version (`IrFunction.version`): the same function object
 * has the same contribution, so it is not read again. A version names one function, so the versions a
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
