import compiler.Compiler;
import compiler.ir.IrInterpreter;
import compiler.Diagnostic.CompileError;

/** Cached callers must use the current method body and payload shape for inline optional places. */
class NullableStructIncrementalMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Point.hx", "struct Point { public var x:Int; public function new(x:Int) this.x = x; public function bump():Void x++; }");
		compiler.update("Holder.hx", "class Holder { public var value:Null<Point>; public function new() value = new Point(1); }");
		compiler.update("Main.hx", "function main():Int { var h = new Holder(); if (h.value != null) h.value.bump(); return h.value == null ? 0 : h.value.x; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 2) throw "initial optional method failed";
		compiler.update("Point.hx", "struct Point { public var x:Int; public function new(x:Int) this.x = x; public function bump():Void x += 2; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 3) throw "optional method retained a stale body";
		compiler.update("Point.hx", "struct Point { public var x:Int; public var y:Int; public function new(x:Int) { this.x = x; y = 4; } public function bump():Void x += y; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 5) throw "optional field retained a stale payload layout";
		var effects = new Compiler();
		effects.update("Counter.hx", "class Counter { public static var calls:Int = 0; public static function observe(x:Int):Int { calls++; return x; } }");
		effects.update("Value.hx", "struct Value { public var x:Int; public function new() x = 1; public function read():Int return Counter.observe(this.x + x - 1); }");
		effects.update("Main.hx", "function make():Value return new Value(); function main():Int return make().read();");
		if (new IrInterpreter(effects.compile("Main").ir).run("main") != 1) throw "read-only impure method failed";
		effects.update("Value.hx", "struct Value { public var x:Int; public function new() x = 1; public function read():Int { Counter.calls++; x++; return x; } }");
		var rejected = false;
		try effects.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1027";
		if (!rejected) throw "cached temporary call ignored a newly mutating method";
		effects.update("Value.hx", "struct Value { public var x:Int; public function new() x = 1; public function read():Int return helper(); "
			+ "function helper():Int { x++; return x; } }");
		rejected = false;
		try effects.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1027";
		if (!rejected) throw "temporary call ignored a mutating receiver method";
		var getter = new Compiler();
		getter.update("Main.hx", "struct Value { public var x:Int; public var current(get, never):Int; public function new() x = 1; "
			+ "function get_current():Int { x++; return x; } public function read():Int return this.current; } "
			+ "function main():Int return new Value().read();");
		var getterRejected = false;
		try getter.compile("Main") catch (error:CompileError) getterRejected = error.diagnostic.code == "E1027";
		if (!getterRejected) throw "temporary call ignored a mutating receiver getter";
		var scalar = new Compiler();
		scalar.update("Value.hx", "struct Value { public var x:Int; public function new(x:Int) this.x = x; }");
		scalar.update("Main.hx", "function pass(v:Null<Value>):Null<Value> return v; "
			+ "function main():Int { var v:Null<Value> = new Value(4); var result = pass(v); return result == null ? 0 : result.x; }");
		if (new IrInterpreter(scalar.compile("Main").ir).run("main") != 4) throw "initial scalar optional call failed";
		scalar.update("Value.hx", "struct Value { public var x:Int; public var y:Int; public function new(x:Int) { this.x = x + 3; y = 3; } }");
		if (new IrInterpreter(scalar.compile("Main").ir).run("main") != 7) throw "scalar optional call retained its previous layout";
		Sys.println("PASS: inline optional fields follow incremental method and layout edits");
	}
}
