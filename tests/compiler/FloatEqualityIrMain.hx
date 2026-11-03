import compiler.Frontend;
import compiler.ir.IrInterpreter;

/** The reference interpreter must use IEEE equality even when an SSA value compares with itself. */
class FloatEqualityIrMain {
	static function main():Void {
		var interpreter = new IrInterpreter(Frontend.compile('function same(value:Float):Bool return value == value; '
			+ 'function equal(a:Float,b:Float):Bool return a == b; function main():Int return 42;'));
		var nan = haxe.io.FPHelper.i64ToDouble(1, 0xfff80000);
		var positiveInfinity = haxe.io.FPHelper.i64ToDouble(0, 0x7ff00000);
		var negativeInfinity = haxe.io.FPHelper.i64ToDouble(0, 0xfff00000);
		if (interpreter.run("same", [nan])) throw "NaN compared equal to itself in the IR interpreter";
		if (!interpreter.run("equal", [0.0, -0.0])) throw "zero signs compared unequal";
		if (interpreter.run("equal", [positiveInfinity, negativeInfinity])) throw "opposite infinities compared equal";
		if (!interpreter.run("same", [positiveInfinity])) throw "infinity did not compare equal to itself";
		Sys.println("PASS: the IR interpreter uses IEEE Float equality");
	}
}
