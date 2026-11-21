package compiler.ir;

import compiler.ir.Ir;

/**
 * Tables indexed by value id that the analyses of one function at a time reuse, so they allocate nothing per function for
 * them. Value ids are dense within a function, so an array indexed by id replaces a map. Whoever runs the passes owns one
 * (the inliner, a backend's lowering) and passes it to each; a pass uses it for the length of its run, and what it leaves
 * there means nothing to the next one. Not for sharing between threads.
 */
class IrPassScratch {
	/** Value ids marked during a pass. */
	public final marked = new IrValueMarks();

	/** The tables of `IrNonNullFacts`. */
	public final nonNull = new IrNonNullScratch();

	/** A worklist of value ids, for the passes over bodies. */
	public final pendingIds:Array<Int> = [];

	/** Two tables of Ints by value or block id, for the passes over bodies. */
	public final firstInts:Array<Int> = [];

	public final secondInts:Array<Int> = [];

	/** The graph of the function a pass reads, refilled for each (`IrGraph.reset`) and released when the pass is done. */
	public final graph = new IrGraph();

	/** The tables of `IrBodyLoadStoreForwarding`. */
	public final bodyLoadStore = new IrLoadStoreForwarding.IrBodyLoadStoreScratch();

	/** A third table of Ints by value or block id, and a list of block ids, for the passes over bodies. */
	public final thirdInts:Array<Int> = [];

	public final blockList:Array<Int> = [];

	/** Two flat lists of tuples of Ints, for the passes over bodies that record a few edits before making them. */
	public final firstTuples:Array<Int> = [];

	public final secondTuples:Array<Int> = [];

	/** The graph the passes over bodies refill (`IrBodyGraph.reset`). */
	public final bodyGraph = new IrBodyGraph();

	/** The tables of `IrScalarReplacement.runBody`. */
	public final scalarReplacement = new IrScalarReplacement.IrBodyScalarReplacement();

	/** The tables of `IrCopyElision.runBody`. */
	public final copyElision = new IrCopyElision.IrBodyCopyElision();

	/** The builder that copies and compactions of bodies reuse (`IrBody.freeze`, `IrBody.thaw`). */
	public final bodyBuilder = new IrBodyBuilder(new IrTypeIds());

	/** The inliner's expansion of a call by a branching callee, its tables reused. */
	public final callExpansion = new IrBodyCallExpansion();

	public function new() {}

	/** `values` with `count` entries, each `value`; its storage is kept between uses. */
	public static function filledInts(values:Array<Int>, count:Int, value:Int):Array<Int> {
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
		return values;
	}

	public static function filledBools(values:Array<Bool>, count:Int, value:Bool):Array<Bool> {
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
		return values;
	}
}

/** A set of small non-negative ids that is emptied in constant time: an id is in it when its stamp is the current one. */
class IrValueMarks {
	final stamps:Array<Int> = [];
	var stamp = 1;

	public function new() {}

	/** Empties the set. */
	public function clear():Void {
		stamp++;
		if (stamp == 0x3FFFFFFF) {
			for (index in 0...stamps.length)
				stamps[index] = 0;
			stamp = 1;
		}
	}

	public inline function has(id:Int):Bool
		return id < stamps.length && stamps[id] == stamp;

	/** Adds `id`; whether it was not in the set already. */
	public function add(id:Int):Bool {
		while (stamps.length <= id)
			stamps.push(0);
		if (stamps[id] == stamp)
			return false;
		stamps[id] = stamp;
		return true;
	}
}

/** The per-value and per-block rows of `IrNonNullFacts`, kept between functions. */
class IrNonNullScratch {
	public final positions:Array<Int> = [];
	public final nulls:Array<Bool> = [];
	public final testValue:Array<Int> = [];
	public final testOnTrue:Array<Bool> = [];
	public final before:Array<Int> = [];
	public final after:Array<Int> = [];
	public final incoming:Array<Int> = [];
	public final outgoing:Array<Int> = [];
	public final fresh:Array<Int> = [];

	/** The facts of the last analysis (`IrNonNullFacts.has`). */
	public final provenStart:Array<Int> = [];

	public final provenLength:Array<Int> = [];
	public final provenWords:Array<Int> = [];

	/** The rows of a body whose receiver the last analysis of a body proved non-null (`IrNonNullFacts.analyzeBody`). */
	public final provenRows = new IrValueMarks();

	public function new() {}
}
