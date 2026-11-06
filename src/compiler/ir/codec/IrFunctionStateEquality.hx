package compiler.ir.codec;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;

/** Conservative, allocation-light equality of all state encoded by IrFunctionStateCodec. */
class IrFunctionStateEquality {
	static final arrayClass = Type.getClass([]);

	public static function same(left:IrFunction, right:IrFunction):Bool {
		if (left == right)
			return true;
		if (left.name != right.name
			|| left.inlineHint != right.inlineHint
			|| left.retention != right.retention
			|| !operand(left.result, right.result)
			|| left.arguments.length != right.arguments.length
			|| left.blocks.length != right.blocks.length
			|| left.debugBindings.length != right.debugBindings.length)
			return false;
		for (i in 0...left.arguments.length)
			if (!value(left.arguments[i], right.arguments[i]))
				return false;
		for (i in 0...left.debugBindings.length) {
			var a = left.debugBindings[i], b = right.debugBindings[i];
			if (a.identity != b.identity || a.name != b.name || a.path != b.path || a.scopeStart != b.scopeStart || a.scopeEnd != b.scopeEnd
				|| !value(a.value, b.value))
				return false;
		}
		for (i in 0...left.blocks.length) {
			var a = left.blocks[i], b = right.blocks[i];
			if (a == b)
				continue;
			if (a.id != b.id || a.instructions.length != b.instructions.length)
				return false;
			for (j in 0...a.instructions.length) {
				var x = a.instructions[j], y = b.instructions[j];
				if (x != y && (!provenance(x.provenance, y.provenance) || !operand(x.value, y.value)))
					return false;
			}
			var x = a.terminator, y = b.terminator;
			if (x != y && (x == null || y == null || !provenance(x.provenance, y.provenance) || !operand(x.value, y.value)))
				return false;
		}
		return true;
	}

	static function value(a:IrValue, b:IrValue):Bool
		return a == b || (a.id == b.id && a.name == b.name && operand(a.type, b.type));

	static function provenance(a:SourceProvenance, b:SourceProvenance):Bool {
		if (a == b)
			return true;
		if (!operand(a.origin, b.origin))
			return false;
		var x = a.location, y = b.location;
		return x == y
			|| (x != null && y != null && x.path == y.path && x.start == y.start && x.end == y.end && x.line == y.line && x.column == y.column
				&& x.endLine == y.endLine && x.endColumn == y.endColumn && x.sourceHash == y.sourceHash);
	}

	static function operand(a:Dynamic, b:Dynamic):Bool {
		// IEEE equality equates -0 with +0 and cannot distinguish NaN payloads; the state codec preserves their bits.
		var kind = Type.typeof(a);
		switch kind {
			case TFloat:
				if (Type.typeof(b) != TFloat)
					return false;
				var x = haxe.io.FPHelper.doubleToI64(a), high = x.high, low = x.low;
				var y = haxe.io.FPHelper.doubleToI64(b);
				return high == y.high && low == y.low;
			default:
		}
		if (a == b)
			return true;
		return switch [kind, Type.typeof(b)] {
			case [TEnum(x), TEnum(y)] if (x == y):
				if (Type.enumIndex(a) != Type.enumIndex(b)) false; else array(Type.enumParameters(a), Type.enumParameters(b));
			case [TClass(x), TClass(y)] if (x == y):
				if (x == arrayClass) array(a, b); else if (x == IrValue) value(a, b); else false;
			case [TObject, TObject]:
				var fields = Reflect.fields(a),
					others = Reflect.fields(b),
					same = fields.length == others.length;
				for (field in fields)
					if (!Reflect.hasField(b, field) || !operand(Reflect.field(a, field), Reflect.field(b, field))) {
						same = false;
						break;
					}
				same;
			default: false;
		};
	}

	static function array(a:Array<Dynamic>, b:Array<Dynamic>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (!operand(a[i], b[i]))
				return false;
		return true;
	}
}
