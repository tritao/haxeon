package compiler.ir.reuse;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIds;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * A whole-program walk or step at one place in the pipeline as a kind of the session's database (docs/design/QUERY_ENGINE.md,
 * Whole-program steps): what it reads, settled once per build (`settle`), and the memo of its result, whose reads are keys of the
 * kind. Key 0 is what its caller gave it, the program's tables (`IrWalkTables`) and the names, order, retention and provider rows
 * of the functions it may read; for the function whose name's number is `k`, key `2k + 1` is its summary `S` (its edges,
 * `IrWalkSummary`, or what a step reads of it), read where the walk follows it (`summary`) and made the first time a walk does,
 * and key `2k + 2` its signature, read where the walk reads its arguments' or result's types (`signature`). Each changes when what it stands for does: a function given
 * as the same object as last build is not looked at, one that is not is compared by its role, its signature and, when a walk
 * read its summary, its summary (`same`). The memo holds while none of its reads changed since it was verified, and a build then
 * takes its result without walking (`kept`): an edit of a signature only the walks that read it decide again.
 */
@:nullSafety(Strict)
class IrWalkMemo<S, R> extends QueryKindBase {
	var tables:Null<IrWalkTables> = null;
	var given:Array<String> = [];
	var givenTypes:Array<Int> = [];

	/** The keys of the functions in their order, and by key the function settled last and its summary (none for a walk without). */
	var order:Array<Int> = [];

	var functions:Array<Null<IrFunction>> = [];
	var summaries:Array<Null<S>> = [];

	/** Whether two summaries of a function say the same to the walk. */
	final same:(S, S) -> Bool;

	/** What reads a function's summary in the build under way (`settle`), for `--check-reuse`. */
	var reader:Null<IrFunction->S> = null;

	/** The memo: the result, the keys its walk read (key 0 first), and the revision it was last verified at. */
	var result:Null<R> = null;

	final reads:Array<Int> = [];
	var verified = 0;
	var recording = false;

	/** `--check-reuse` in the walk under way: each summary it reads is read again from its function and compared. */
	var checking = false;

	/**
	 * By key, the walk that last read the function's keys, shifted left by two, and which it read (1 its summary, 2 its signature),
	 * so a walk records each read once.
	 */
	var readMarks:Array<Int> = [];

	var walks = 0;

	/**
	 * The session's walks that read the same summaries, this one among them, which share the summary of a function they are given as
	 * the same object; null for a walk whose summaries are its own.
	 */
	final session:Null<Array<IrWalkMemo<S, Dynamic>>>;

	public function new(name:String, same:(S, S) -> Bool, session:Null<Array<IrWalkMemo<S, Dynamic>>>) {
		super(name);
		this.same = same;
		this.session = session;
		settled = true;
		changes.push(0);
	}

	/**
	 * Brings each key up to date with `program`, the walk's `functions` in order, what its caller gives it as names and type ids, and,
	 * with `read`, the functions' summaries.
	 */
	public function settle(database:QueryDatabase, program:IrProgram, functions:Array<IrFunction>, given:Array<String>,
			givenTypes:Array<Int>, read:Null<IrFunction->S>):Void {
		// A memo verified in this revision is told apart from what changes now by a revision of its own.
		var revision = verified == database.revision ? database.advance() : database.revision,
			known = tables,
			whole = false;
		reader = read;
		if (known == null || !known.holds(program)) {
			tables = new IrWalkTables(program);
			whole = true;
		}
		if (!IrObjectTools.sameNames(given, this.given) || !IrTypeIds.sameList(givenTypes, this.givenTypes)) {
			this.given = given;
			this.givenTypes = givenTypes;
			whole = true;
		}
		var order = this.order, kept = this.functions;
		if (functions.length != order.length)
			whole = true;
		for (index in 0...functions.length) {
			var fn = functions[index], key = fn.symbol.functionKey();
			if (!whole && order[index] != key)
				whole = true;
			if (key >= kept.length) {
				// As long as the names numbered, with a little room: half again would leave a third of each column empty.
				var named = compiler.ir.model.IrSymbol.functionKeysGiven(), length = named + (named >> 4);
				kept.resize(length);
				QueryRead.extend(readMarks, length);
				QueryRead.extend(changes, 2 * length + 1);
			}
			if (read != null && key >= summaries.length)
				summaries.resize(kept.length);
			var last = kept[key];
			if (last == fn)
				continue;
			if (last == null || !IrWalkTables.sameRole(fn, last))
				whole = true;
			else if (!IrWalkTables.sameSignature(fn, last))
				changes[2 * key + 2] = revision;
			// The summary is found before the function is kept: this walk's own, of the function it held, is not `fn`'s. A function
			// whose summary no walk read gets one only when a walk reads it (`summary`): nothing read the one it had.
			if (read != null) {
				var before = summaries[key];
				if (before == null)
					changes[2 * key + 1] = revision;
				else {
					var now = sharedSummary(key, fn, read);
					summaries[key] = now;
					if (!same(before, now))
						changes[2 * key + 1] = revision;
				}
			}
			kept[key] = fn;
		}
		if (!whole)
			return;
		changes[0] = revision;
		var now = [for (fn in functions) fn.symbol.functionKey()];
		// A function the program lost, in the old order and not in the new one, is let go.
		if (order.length > 0) {
			var lost:Array<Int> = [];
			QueryRead.extend(lost, kept.length);
			for (key in order)
				lost[key] = 1;
			for (key in now)
				lost[key] = 0;
			for (key in order)
				if (lost[key] != 0) {
					kept[key] = null;
					if (key < summaries.length)
						summaries[key] = null;
					changes[2 * key + 1] = revision;
					changes[2 * key + 2] = revision;
				}
		}
		this.order = now;
	}

	/**
	 * Settles the walk's reads (`settle`), and returns the memo's result when none of what its walk read changed since, verified now;
	 * else null, and the caller walks between `begin` and `end`.
	 */
	public function kept(database:QueryDatabase, program:IrProgram, functions:Array<IrFunction>, given:Array<String>,
			givenTypes:Array<Int>, read:Null<IrFunction->S>):Null<R> {
		settle(database, program, functions, given, givenTypes, read);
		var known = result;
		if (known == null)
			return null;
		for (key in reads)
			if (changes[key] > verified)
				return null;
		verified = database.revision;
		reader = null;
		return known;
	}

	/** Starts a walk: the keys read until `end` are the memo's. */
	public function begin(database:QueryDatabase):Void {
		checking = database.checkReuse;
		walks++;
		reads.resize(0);
		reads.push(0);
		recording = true;
	}

	/** Ends the walk `begin` started, with its result. */
	public function end(database:QueryDatabase, value:R):Void {
		result = value;
		verified = database.revision;
		recording = false;
		reader = null;
	}

	/** What another walk settled for `fn`, whose key is `key`, when it was given the same object; else read now. */
	function sharedSummary(key:Int, fn:IrFunction, read:IrFunction->S):S {
		var walks = session;
		if (walks != null)
			for (walk in walks) {
				var known = walk.settledSummary(key, fn);
				if (known != null)
					return known;
			}
		return read(fn);
	}

	/** The summary this walk settled for `fn`, whose key is `key`, when it settled that object, else null. */
	public function settledSummary(key:Int, fn:IrFunction):Null<S>
		return key < summaries.length && functions[key] == fn ? summaries[key] : null;

	/** The summary of `fn`, one of the functions settled, recorded as a read of the walk under way. */
	public function summary(fn:IrFunction):S {
		var key = settledKey(fn, "summary"), known = key < summaries.length ? summaries[key] : null, read = reader;
		if (known == null) {
			if (read == null || key >= summaries.length)
				throw new InternalError('the walk $kindName reads the summary of ${fn.name}, which it settled without one');
			summaries[key] = known = sharedSummary(key, fn, read);
		} else if (checking && read != null && !same(known, read(fn)))
			throw new InternalError('--check-reuse: the walk $kindName reused a summary of ${fn.name} that differs from its instructions');
		if (recording && readMarks[key] & 1 == 0) {
			readMarks[key] |= 1;
			reads.push(2 * key + 1);
		}
		return known;
	}

	/** Records that the walk under way reads the types of the arguments and result of `fn`, one of the functions settled. */
	public function signature(fn:IrFunction):Void {
		var key = settledKey(fn, "signature");
		if (recording && readMarks[key] & 2 == 0) {
			readMarks[key] |= 2;
			reads.push(2 * key + 2);
		}
	}

	/** The key of `fn`, which the walk must have settled as that object; a walk reads its `what` (`summary`, `signature`). */
	function settledKey(fn:IrFunction, what:String):Int {
		var key = fn.symbol.functionKey();
		if (key >= functions.length || functions[key] != fn)
			throw new InternalError('the walk $kindName reads the $what of ${fn.name}, which it did not settle');
		if (recording && readMarks[key] >> 2 != walks)
			readMarks[key] = walks << 2;
		return key;
	}

	override public function changedAt(database:QueryDatabase, key:Int):Int
		return key < changes.length ? changes[key] : database.revision;

	override public function describe(key:Int):String
		return kindName + "(" + (key == 0 ? "program" : (key & 1 == 1 ? "summary of " : "signature of ")
			+ compiler.ir.model.IrSymbol.ofFunctionKey((key - 1) >> 1).name) + ")";

	public function clear():Void {
		tables = null;
		given = [];
		givenTypes = [];
		order = [];
		functions = [];
		summaries = [];
		readMarks = [];
		result = null;
		reader = null;
		reads.resize(0);
		verified = 0;
		changes.resize(1);
		changes[0] = 0;
	}
}
