package compiler.ir.reuse;

import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIdentity;

/**
 * A whole-program walk a session keeps with what it read, so the next build takes its result while the program gives the walk the
 * same, and walks again otherwise. Every kept walk reads the same kinds of input: the program's tables (classes, interfaces, natives,
 * C natives, static fields, enums), what its caller gives it (roots and settings as names, root types), the declaration of each
 * function it may read, and of each function it reached, a summary `S` of that function's edges. A build with the same tables and
 * given inputs, whose functions are the same objects or, for one that is not, the same declaration and, when it was reached, a
 * summary with the same edges, walks to the same result `R`: a function the walk did not reach adds nothing through its body.
 *
 * The tables are kept as copies of the program's lists, whose entries are never changed once made, since a later stage may add to
 * a list.
 */
@:nullSafety(Strict)
class IrWalkRecord<S, R> {
	final objects:Array<IrObject>;
	final interfaces:Array<IrInterface>;
	final natives:Array<IrNative>;
	final cNatives:Array<IrCNative>;
	final staticFields:Array<IrStaticField>;
	final enums:Array<IrEnum>;

	/** What the caller gave the walk besides the program: its roots and settings, as names and as types. */
	final given:Array<String>;

	final givenTypes:Array<IrType>;

	/** The functions whose declarations the walk read. */
	final functions:Array<IrFunction>;

	/** By position in `functions`: the summary the walk followed, or null for a function it did not reach. */
	final summaries:Array<Null<S>>;

	public final result:R;

	/** The record of a walk of `program`, given `given` and `givenTypes`, that read `functions` and `summaries` and found `result`. */
	public function new(program:IrProgram, given:Array<String>, givenTypes:Array<IrType>, functions:Array<IrFunction>,
			summaries:Array<Null<S>>, result:R) {
		objects = program.objects.copy();
		interfaces = program.interfaces.copy();
		natives = program.natives.copy();
		cNatives = program.cNatives.copy();
		staticFields = program.staticFields.copy();
		enums = program.enums.copy();
		this.given = given;
		this.givenTypes = givenTypes;
		this.functions = functions;
		this.summaries = summaries;
		this.result = result;
	}

	/**
	 * This walk's result as the record of a walk of `program` now; null when the program or the caller gives the walk something else.
	 * `read(fn, last)` is the summary of reached function `fn` now when it has the edges of `last`, else null. A function that stayed
	 * is not looked at: the record keeps its summary, which a walk done again takes back (`eachSummary`).
	 */
	public function holds(program:IrProgram, given:Array<String>, givenTypes:Array<IrType>, functions:Array<IrFunction>,
			read:(IrFunction, S) -> Null<S>):Null<IrWalkRecord<S, R>> {
		if (functions.length != this.functions.length || !IrObjectTools.sameNames(given, this.given)
			|| !IrTypeIdentity.sameList(givenTypes, this.givenTypes) || !sameTables(program))
			return null;
		var kept:Null<Array<Null<S>>> = null;
		for (index in 0...functions.length) {
			var fn = functions[index], last = this.functions[index];
			if (fn == last)
				continue;
			var summary = summaries[index];
			if (fn.name != last.name || !sameDeclaration(fn, last))
				return null;
			if (summary == null)
				continue;
			var now = read(fn, summary);
			if (now == null)
				return null;
			if (kept == null)
				kept = summaries.copy();
			kept[index] = now;
		}
		return new IrWalkRecord(program, given, givenTypes, functions.copy(), kept ?? summaries, result);
	}

	/**
	 * Gives `memo` back the summaries the walk followed of the functions that still stand in `lineage`, for a walk done again:
	 * while the record held, nothing asked the memo for them, so it may have let them go.
	 */
	public function giveBack(memo:compiler.ir.reuse.IrStageMemo.IrContributionMemo<S>,
			lineage:compiler.ir.reuse.IrStageMemo.IrLineage):Void
		for (index in 0...functions.length) {
			var summary = summaries[index];
			if (summary == null)
				continue;
			var version = lineage.versionOf(functions[index]);
			if (version != 0 && memo.get(version) == null)
				memo.keep(version, summary);
		}

	/** Tells `each` of every reached function and the summary the walk followed, for a walk done again (`giveBack`). */
	public function eachSummary(each:(IrFunction, S) -> Void):Void
		for (index in 0...functions.length) {
			var summary = summaries[index];
			if (summary != null)
				each(functions[index], summary);
		}

	/** Whether two functions of one name declare the same to a walk: provider row, retention and signature. */
	static function sameDeclaration(left:IrFunction, right:IrFunction):Bool {
		if (left.retention != right.retention || left.arguments.length != right.arguments.length
			|| !IrTypeIdentity.same(left.result, right.result))
			return false;
		for (index in 0...left.arguments.length)
			if (!IrTypeIdentity.same(left.arguments[index].type, right.arguments[index].type))
				return false;
		return switch [left.provides, right.provides] {
			case [None, None]: true;
			case [Serves(leftType, leftOperation), Serves(rightType, rightOperation)]:
				leftOperation == rightOperation && leftType.toString() == rightType.toString();
			default: false;
		};
	}

	/**
	 * The last two lists of objects found the same shape, the kept one and the program's: the records kept at one place in the
	 * pipeline hold the same objects, so each after the first compares them by identity.
	 */
	@:processWide("a pair of lists whose objects are never changed, replaced whole; a stale pair only costs a full comparison")
	static var sameShapes:Null<{
		kept:Array<IrObject>,
		now:Array<IrObject>
	}> = null;

	/** Whether `program`'s tables give a walk what these gave it. */
	function sameTables(program:IrProgram):Bool {
		if (program.objects.length != objects.length || program.interfaces.length != interfaces.length
			|| program.natives.length != natives.length || program.cNatives.length != cNatives.length
			|| program.staticFields.length != staticFields.length || program.enums.length != enums.length)
			return false;
		var shapes = sameShapes;
		if (shapes == null || !sameEntries(shapes.kept, objects) || !sameEntries(shapes.now, program.objects)) {
			for (index in 0...objects.length)
				if (!IrObjectTools.sameShape(program.objects[index], objects[index]))
					return false;
			sameShapes = {kept: objects, now: program.objects.copy()};
		}
		for (index in 0...interfaces.length) {
			var left = program.interfaces[index], right = interfaces[index];
			if (left == right)
				continue;
			if (left.name != right.name || !IrObjectTools.sameNames(left.bases, right.bases)
				|| left.methods.length != right.methods.length)
				return false;
			for (method in 0...left.methods.length) {
				var a = left.methods[method], b = right.methods[method];
				if (a.name != b.name || !IrTypeIdentity.same(a.result, b.result)
					|| !IrTypeIdentity.sameList(a.arguments, b.arguments))
					return false;
			}
		}
		for (index in 0...natives.length) {
			var left = program.natives[index], right = natives[index];
			if (left != right
				&& (left.name != right.name || left.symbol != right.symbol
				|| !IrTypeIdentity.same(left.result, right.result)
				|| !IrTypeIdentity.sameList(left.arguments, right.arguments)
				|| !sameOptionalNames(left.generatedFunctionDependencies, right.generatedFunctionDependencies)))
				return false;
		}
		for (index in 0...cNatives.length) {
			var left = program.cNatives[index], right = cNatives[index];
			if (left != right
				&& (left.name != right.name || !IrTypeIdentity.same(left.result, right.result)
				|| !IrTypeIdentity.sameList(left.arguments, right.arguments)))
				return false;
		}
		for (index in 0...staticFields.length) {
			var left = program.staticFields[index], right = staticFields[index];
			if (left != right && (left.name != right.name || !IrTypeIdentity.same(left.type, right.type)))
				return false;
		}
		for (index in 0...enums.length) {
			var left = program.enums[index], right = enums[index];
			if (left == right)
				continue;
			if (left.name != right.name || left.cases.length != right.cases.length)
				return false;
			for (item in 0...left.cases.length)
				if (!IrTypeIdentity.sameList(left.cases[item].params, right.cases[item].params))
					return false;
		}
		return true;
	}

	/** Whether two lists hold the same objects, in order. */
	static function sameEntries(left:Array<IrObject>, right:Array<IrObject>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function sameOptionalNames(left:Null<Array<String>>, right:Null<Array<String>>):Bool
		return left == null || right == null ? left == right : IrObjectTools.sameNames(left, right);
}
