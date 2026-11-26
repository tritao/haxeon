package compiler.ir.reuse;

import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIdentity;

/**
 * What a whole-program walk reads of the program besides its functions: copies of its tables (classes, interfaces, natives, C
 * natives, static fields, enums), whose entries are never changed once made, since a later stage may add to a list; and what it
 * reads of a function it does not follow, its declaration (`sameDeclaration`). A walk kept across builds holds while the program's
 * tables are the same (`holds`) (`IrWalkMemo`, `IrWalkRecord`).
 */
@:nullSafety(Strict)
class IrWalkTables {
	final objects:Array<IrObject>;
	final interfaces:Array<IrInterface>;
	final natives:Array<IrNative>;
	final cNatives:Array<IrCNative>;
	final staticFields:Array<IrStaticField>;
	final enums:Array<IrEnum>;

	public function new(program:IrProgram) {
		objects = program.objects.copy();
		interfaces = program.interfaces.copy();
		natives = program.natives.copy();
		cNatives = program.cNatives.copy();
		staticFields = program.staticFields.copy();
		enums = program.enums.copy();
	}

	/** Whether two functions of one name declare the same to a walk: provider row, retention and signature. */
	public static function sameDeclaration(left:IrFunction, right:IrFunction):Bool {
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
	public function holds(program:IrProgram):Bool {
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
