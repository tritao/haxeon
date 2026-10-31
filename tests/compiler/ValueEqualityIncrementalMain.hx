import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** A cached caller must pick up a value type's added comparison field. */
class ValueEqualityIncrementalMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Point.hx", "struct Point { public var x:Int; public function new(seed:Int) x = seed % 2; }");
		compiler.update("Main.hx", "function main():Int { var a = new Point(1); var b = new Point(3); return a == b ? 1 : 2; }");
		var first = compiler.compile("Main");
		if (new IrInterpreter(first.ir).run("main") != 1)
			throw "value equality did not compare the original field";
		compiler.update("Point.hx",
			"struct Point { public var x:Int; public var y:Int; public function new(seed:Int) { x = seed % 2; y = seed; } }");
		var changed = compiler.compile("Main");
		if (new IrInterpreter(changed.ir).run("main") != 2)
			throw "value equality retained a stale field list after a layout edit";
		Sys.println("PASS: value equality follows incremental changes to its fields");
	}
}
