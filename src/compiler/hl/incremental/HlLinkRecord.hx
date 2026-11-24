package compiler.hl.incremental;

import compiler.hl.HlCode.HlConstant;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.incremental.HlSymbolTable.HlTableLengths;

/**
 * The tables a plain build's lowering made, with what made them, so the next build can keep them instead of asking every function's
 * requests again (`HlLower`). Lowering makes the tables in order: the metadata (classes, enums, interfaces, static fields,
 * natives), then the requests of each function in program order, then those of the String constants. The first time a build asks
 * a request is what adds to the tables, so a build with the same metadata and function layout whose functions first ask the same
 * requests in the same order makes the same tables, and every request gets the answer it got here.
 *
 * So a build that keeps them starts from these tables (shared, never changed). A function whose lowering it keeps as it is,
 * at the position it had, asks nothing; one it lowers or links again asks against the kept tables, and what it first asked is
 * checked against what it first asked here (`HlKeptTables`). A String, integer, float or String constant that only one function
 * asked for, and that no other entry refers to, may give way to one no build asked for: the new one takes its index, so nothing
 * else moves. Any other difference lowers the build again with fresh tables.
 */
class HlLinkRecord {
	/** The tables as the metadata left them. */
	public final metadata:HlTableArrays;

	/** The function layout: the name in each slot. */
	public final slots:Array<String>;

	/** The lowered function at each position of the program. */
	public final functions:Array<HlLoweredFunction>;

	/** The requests the String constants asked, after every function's, and their answers. */
	public final constantKeys:Array<Int>;

	public final constantAnswers:Array<Int>;
	public final constants:Array<HlConstant>;

	/** The tables lowering made; a build that keeps them shares them (`HlSymbolTable.shareFrom`). */
	public final tables:HlSymbolTable;

	public final lengths:HlTableLengths;

	/** By request, the position of the first function that asked it (the constants are one past the last function), or -1. */
	var firstAskers:Null<Array<Int>> = null;

	/** By request, how many positions asked it. */
	var askerCounts:Null<Array<Int>> = null;

	public function new(metadata:HlTableArrays, slots:Array<String>, functions:Array<HlLoweredFunction>,
			constantKeys:Array<Int>, constantAnswers:Array<Int>, constants:Array<HlConstant>, tables:HlSymbolTable) {
		this.metadata = metadata;
		this.slots = slots;
		this.functions = functions;
		this.constantKeys = constantKeys;
		this.constantAnswers = constantAnswers;
		this.constants = constants;
		this.tables = tables;
		lengths = tables.lengths();
	}

	/** Whether the tables as the metadata left them, and the function layout `slots`, are the ones these tables were made after. */
	public function fits(metadata:HlTableArrays, slots:Array<String>):Bool
		return compiler.ir.model.Ir.IrObjectTools.sameNames(slots, this.slots) && metadata.same(this.metadata);

	/** The keys position `position` asked (the constants at `functions.length`). */
	public function keysAt(position:Int):Array<Int>
		return position == functions.length ? constantKeys : functions[position].keys;

	public function firstAsker(key:Int):Int {
		count();
		var known = firstAskers;
		return known == null || key >= known.length ? -1 : known[key];
	}

	public function askers(key:Int):Int {
		count();
		var known = askerCounts;
		return known == null || key >= known.length ? 0 : known[key];
	}

	/**
	 * Takes the counts of `last`, whose tables this record kept, with the positions this build asked again (`HlKeptTables.asked`)
	 * counted anew, so a build counts only what changed. Left to `count` when a request that one of them no longer asks has
	 * another first asker.
	 */
	public function inherit(last:HlLinkRecord, changes:Array<{position:Int, keys:Array<Int>}>):Void {
		var lastFirst = last.firstAskers, lastCounts = last.askerCounts;
		if (lastFirst == null || lastCounts == null)
			return;
		var first = lastFirst.copy(), counts = lastCounts.copy(), recount:Array<Int> = [];
		for (change in changes) {
			var position = change.position;
			for (key in last.keysAt(position)) {
				counts[key]--;
				if (first[key] == position)
					recount.push(key);
			}
			for (key in change.keys) {
				while (first.length <= key) {
					first.push(-1);
					counts.push(0);
				}
				counts[key]++;
				if (first[key] < 0 || first[key] > position)
					first[key] = position;
			}
			if (recount.length > 0) {
				var still:Map<Int, Bool> = [for (key in change.keys) key => true];
				for (key in recount)
					if (counts[key] == 0)
						first[key] = -1;
					else if (!still.exists(key))
						return;
				recount.resize(0);
			}
		}
		firstAskers = first;
		askerCounts = counts;
	}

	function count():Void {
		if (firstAskers != null)
			return;
		var first:Array<Int> = [], counts:Array<Int> = [];
		for (position in 0...functions.length + 1)
			for (key in keysAt(position)) {
				while (first.length <= key) {
					first.push(-1);
					counts.push(0);
				}
				if (first[key] < 0)
					first[key] = position;
				counts[key]++;
			}
		firstAskers = first;
		askerCounts = counts;
	}
}

/**
 * The checks of a build that keeps the last build's tables (`HlLinkRecord`): what each function it lowers or links again first asks
 * must be what the same function first asked there, up to leaves that give way to new ones at the same index (`check`).
 */
class HlKeptTables {
	public final record:HlLinkRecord;

	final requests:HlRequestKeys;

	/** The requests whose entries gave way to new ones: no function of this build may ask them. */
	final replaced:Map<Int, Bool> = [];

	/** The requests the functions this build lowered or linked again asked. */
	final asked:Map<Int, Bool> = [];

	/** The positions this build asked again, with what they asked (`HlLinkRecord.inherit`). */
	public final changes:Array<{position:Int, keys:Array<Int>}> = [];

	public function new(record:HlLinkRecord, requests:HlRequestKeys) {
		this.record = record;
		this.requests = requests;
	}

	/**
	 * Checks the requests `keys`, with their `answers` in `symbols`, of the function at `position` (the constants one past the last
	 * function). Returns the leaves to move into place (`HlSymbolTable.replaceLeaf`), or null when the tables cannot stay.
	 */
	public function check(position:Int, keys:Array<Int>, answers:Array<Int>):Null<Array<HlLeafMove>> {
		changes.push({position: position, keys: keys});
		var mine:Array<Int> = [], mineAnswers:Array<Int> = [];
		for (index in 0...keys.length) {
			var key = keys[index];
			if (replaced.exists(key))
				return null;
			asked.set(key, true);
			if (!requests.interns(key))
				continue;
			var first = record.firstAsker(key);
			if (first > position)
				return null;
			if (first == position || first < 0) {
				mine.push(key);
				mineAnswers.push(answers[index]);
			}
		}
		var theirs =
			[for (key in record.keysAt(position)) if (requests.interns(key) && record.firstAsker(key) == position) key];
		if (mine.length != theirs.length)
			return null;
		var moves:Array<HlLeafMove> = [];
		for (index in 0...mine.length) {
			var now = mine[index], before = theirs[index];
			if (now == before)
				continue;
			// A leaf no build asked for, in place of one only this position asked for and nothing else refers to.
			var table = leafTable(requests.request(now));
			if (table < 0 || table != leafTable(requests.request(before)) || record.firstAsker(now) >= 0
				|| record.askers(before) != 1 || asked.exists(before))
				return null;
			var to = previousAnswer(position, before), from = mineAnswers[index];
			var kept = tableLength(record.lengths, table);
			if (to < metadataLength(table) || to >= kept || from < kept
				|| table == HlRequestKeys.STRINGS && record.tables.typesName(to))
				return null;
			replaced.set(before, true);
			moves.push({table: table, from: from, to: to});
		}
		return moves;
	}

	function previousAnswer(position:Int, key:Int):Int {
		var keys = record.keysAt(position),
			answers = position == record.functions.length ? record.constantAnswers : record.functions[position].answers;
		for (index in 0...keys.length)
			if (keys[index] == key)
				return answers[index];
		return -1;
	}

	function metadataLength(table:Int):Int
		return tableLength(record.metadata.lengths(), table);

	static function tableLength(lengths:HlTableLengths, table:Int):Int
		return switch table {
			case HlRequestKeys.INTS: lengths.ints;
			case HlRequestKeys.FLOATS: lengths.floats;
			case HlRequestKeys.STRINGS: lengths.strings;
			case HlRequestKeys.GLOBALS: lengths.globals;
			default: lengths.types;
		};

	/** The table a leaf request adds to, or -1 for a request whose entry others may refer to. */
	static function leafTable(request:HlSymbolRequest):Int
		return switch request {
			case ConstInt(_, _): HlRequestKeys.INTS;
			case ConstFloat(_, _): HlRequestKeys.FLOATS;
			case ConstString(_, _): HlRequestKeys.STRINGS;
			case StringLiteral(_, _): HlRequestKeys.GLOBALS;
			default: -1;
		};
}

/** A leaf entry a function of a kept build added at `from`, which goes to `to` in place of the one there (`HlKeptTables.check`). */
typedef HlLeafMove = {
	final table:Int;
	final from:Int;
	final to:Int;
}

/** Copies of a symbol table's entries, to tell whether another build's are the same. */
class HlTableArrays {
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final types:Array<HlTypeDef>;
	final globals:Array<Int>;

	function new(symbols:HlSymbolTable) {
		ints = symbols.ints.copy();
		floats = symbols.floats.copy();
		strings = symbols.strings.copy();
		types = symbols.types.copy();
		globals = symbols.globals.copy();
	}

	public static function of(symbols:HlSymbolTable):HlTableArrays
		return new HlTableArrays(symbols);

	public function lengths():HlTableLengths
		return {
			ints: ints.length,
			floats: floats.length,
			strings: strings.length,
			types: types.length,
			globals: globals.length
		};

	/**
	 * Whether `other` has the same entries. Each key a table maps is answered by its entry, so tables with the same entries answer
	 * every request the same; the keys that only name another entry (a nullable class as `Dynamic`) add nothing either way.
	 */
	public function same(other:HlTableArrays):Bool {
		if (ints.length != other.ints.length || floats.length != other.floats.length
			|| strings.length != other.strings.length || types.length != other.types.length
			|| globals.length != other.globals.length)
			return false;
		for (index in 0...ints.length)
			if (ints[index] != other.ints[index])
				return false;
		for (index in 0...floats.length)
			if (!sameFloat(floats[index], other.floats[index]))
				return false;
		for (index in 0...strings.length)
			if (strings[index] != other.strings[index])
				return false;
		for (index in 0...globals.length)
			if (globals[index] != other.globals[index])
				return false;
		for (index in 0...types.length)
			if (!sameType(types[index], other.types[index]))
				return false;
		return true;
	}

	static function sameType(left:HlTypeDef, right:HlTypeDef):Bool
		return switch [left, right] {
			case [Simple(a), Simple(b)]: a == b;
			case [EnumTag(a, aGlobals), EnumTag(b, bGlobals)]: a == b && sameInts(aGlobals, bGlobals);
			case [Parameterized(a, aParameter), Parameterized(b, bParameter)]: a == b && aParameter == bParameter;
			case [Abstract(a), Abstract(b)]: a == b;
			case [Function(aArguments, a), Function(bArguments, b)] | [Method(aArguments, a), Method(bArguments, b)]:
				a == b && sameInts(aArguments, bArguments);
			case [
				Object(aName, aBase, aGlobal, aFields, aMethods, aBindings),
				Object(bName, bBase, bGlobal, bFields, bMethods, bBindings)
			]:
				aName == bName && aBase == bBase && aGlobal == bGlobal && sameFields(aFields, bFields)
					&& sameMethods(aMethods, bMethods) && sameInts(aBindings, bBindings);
			case [
				Structure(aName, aGlobal, aFields, aMethods, aBindings),
				Structure(bName, bGlobal, bFields, bMethods, bBindings)
			]:
				aName == bName && aGlobal == bGlobal && sameFields(aFields, bFields) && sameMethods(aMethods, bMethods)
					&& sameInts(aBindings, bBindings);
			case [Virtual(aName, aFields), Virtual(bName, bFields)]:
				if (aName != bName || aFields.length != bFields.length) false;
				else {
					var same = true;
					for (index in 0...aFields.length)
						if (aFields[index].name != bFields[index].name || aFields[index].type != bFields[index].type)
							same = false;
					same;
				}
			case [Enum(aName, aGlobal, aConstructors), Enum(bName, bGlobal, bConstructors)]:
				if (aName != bName || aGlobal != bGlobal || aConstructors.length != bConstructors.length) false;
				else {
					var same = true;
					for (index in 0...aConstructors.length)
						if (aConstructors[index].name != bConstructors[index].name
							|| !sameInts(aConstructors[index].params, bConstructors[index].params))
							same = false;
					same;
				}
			default: false;
		};

	/** The table pools floats by their bits: a NaN is never taken for another, nor 0 for -0. */
	static function sameFloat(left:Float, right:Float):Bool
		return left == right && (left != 0 || 1 / left == 1 / right);

	static function sameInts(left:Array<Int>, right:Array<Int>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function sameFields(left:Array<compiler.hl.HlCode.HlObjectField>,
			right:Array<compiler.hl.HlCode.HlObjectField>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index].name != right[index].name || left[index].type != right[index].type)
				return false;
		return true;
	}

	static function sameMethods(left:Array<compiler.hl.HlCode.HlObjectMethod>,
			right:Array<compiler.hl.HlCode.HlObjectMethod>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a.name != b.name || a.functionIndex != b.functionIndex || a.prototype != b.prototype)
				return false;
		}
		return true;
	}
}
