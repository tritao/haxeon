import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** A cached caller must pick up a value type's added comparison field. */
class ValueEqualityIncrementalMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Equatable.hx", "interface Equatable {}");
		compiler.update("Point.hx", "struct Point : Equatable { public var x:Int; public function new(seed:Int) x = seed % 2; }");
		compiler.update("Main.hx", "function main():Int { var a = new Point(1); var b = new Point(3); return a == b ? 1 : 2; }");
		var first = compiler.compile("Main");
		if (new IrInterpreter(first.ir).run("main") != 1)
			throw "value equality did not compare the original field";
		compiler.update("Point.hx",
			"struct Point : Equatable { public var x:Int; public var y:Int; public function new(seed:Int) { x = seed % 2; y = seed; } }");
		var changed = compiler.compile("Main");
		if (new IrInterpreter(changed.ir).run("main") != 2)
			throw "value equality retained a stale field list after a layout edit";
		var declared = new Compiler();
		declared.update("Equatable.hx", "interface Equatable {}");
		declared.update("Record.hx", "class Record implements Equatable { public var x:Int; public function new(seed:Int) x = seed % 2; }");
		declared.update("Main.hx", "function main():Int { var a = new Record(1); var b = new Record(3); return a == b ? 1 : 2; }");
		if (new IrInterpreter(declared.compile("Main").ir).run("main") != 1)
			throw "declared equality did not compare the original field";
		declared.update("Record.hx", "class Record implements Equatable { public var x:Int; public var y:Int; public function new(seed:Int) { x = seed % 2; y = seed; } }");
		if (new IrInterpreter(declared.compile("Main").ir).run("main") != 2)
			throw "declared equality retained a stale field list after a layout edit";
		Sys.println("PASS: value equality follows incremental changes to its fields");
	}
}
