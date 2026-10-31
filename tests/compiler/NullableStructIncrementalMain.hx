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
		var purity = new Compiler();
		purity.update("Value.hx", "struct Inner { public final text:String; public function new(text:String) this.text = text; } "
			+ "struct Value { public final x:Int; public final inner:Inner; public function new(x:Int) { this.x = x; inner = new Inner('ok'); } }");
		purity.update("Holder.hx", "class Holder { public static var changed:Bool = false; public var value:Null<Value>; public var copy(get, never):Value; "
			+ "public function new() value = new Value(4); function get_copy():Value return new Value(7); }");
		purity.update("Main.hx", "function main():Int { var h = new Holder(); return h.value != null && h.copy.inner.text == 'ok' ? h.value.x : 0; }");
		if (new IrInterpreter(purity.compile("Main").ir).run("main") != 4) throw "pure nested value construction lost a field refinement";
		purity.update("Value.hx", "struct Inner { public final text:String; public function new(text:String) this.text = text; } "
			+ "struct Value { public final x:Int; public final inner:Inner; public function new(x:Int) { this.x = x; inner = new Inner('ok'); Holder.changed = true; } }");
		var impureRejected = false;
		try purity.compile("Main") catch (error:CompileError) impureRejected = error.diagnostic.code == "E1005";
		if (!impureRejected) throw "incremental purity ignored a newly effectful constructor";
		var closure = new Compiler();
		closure.update("Main.hx", "struct Value { public final x:Int; public function new(x:Int) this.x = x; } "
			+ "class Holder { public var value:Null<Value>; public function new() value = new Value(4); } "
			+ "function main():Int { var h = new Holder(); var make = function():Value return new Value(7); "
			+ "if (h.value != null) { var result = make(); if (result.x == 7) return h.value.x; } return 0; }");
		if (new IrInterpreter(closure.compile("Main").ir).run("main") != 4) throw "pure construction in a closure lost a field refinement";
		var alias = new Compiler();
		alias.update("Main.hx", "class Cell { public var x:Int; public function new() x = 0; } "
			+ "struct Value { public final cell:Cell; public function new(cell:Cell) { this.cell = cell; cell.x++; } } "
			+ "class Holder { public var value:Null<Value>; public var copy(get, never):Value; public var cell:Cell; "
			+ "public function new() { cell = new Cell(); value = new Value(cell); } function get_copy():Value return new Value(cell); } "
			+ "function main():Int { var h = new Holder(); return h.value != null && h.copy.cell.x > 0 ? h.value.cell.x : 0; }");
		var aliasRejected = false;
		try alias.compile("Main") catch (error:CompileError) aliasRejected = error.diagnostic.code == "E1005";
		if (!aliasRejected) throw "constructor mutation through an argument preserved a nullable field refinement";
		var direct = new Compiler();
		direct.update("Main.hx", "struct Value { public final x:Int; public function new(x:Int) this.x = x; } "
			+ "class Holder { public var value:Null<Value>; public function new() value = new Value(4); } "
			+ "class Mutator { public function new(holder:Holder) holder.value = null; } "
			+ "function main():Int { var h = new Holder(); if (h.value != null) { new Mutator(h); return h.value.x; } return 0; }");
		var directRejected = false;
		try direct.compile("Main") catch (error:CompileError) directRejected = error.diagnostic.code == "E1005";
		if (!directRejected) throw "direct effectful construction preserved a nullable field refinement";
		var pureDirect = new Compiler();
		pureDirect.update("Main.hx", "struct Value { public final x:Int; public function new(x:Int) this.x = x; } "
			+ "class Holder { public var value:Null<Value>; public function new() value = new Value(4); } "
			+ "class Pure { public final value:Int; public function new(value:Int) this.value = value; } "
			+ "function main():Int { var h = new Holder(); if (h.value != null) { var p = new Pure(7); return h.value.x + p.value; } return 0; }");
		if (new IrInterpreter(pureDirect.compile("Main").ir).run("main") != 11) throw "pure direct class construction lost a field refinement";
		var initializer = new Compiler();
		initializer.update("Main.hx", "class Effects { public static function change():Int { Holder.changed = true; return 1; } } "
			+ "struct Value { public final x:Int = Effects.change(); public function new() {} } "
			+ "class Holder { public static var changed:Bool = false; public var value:Null<Value>; public var copy(get, never):Value; "
			+ "public function new() value = new Value(); function get_copy():Value return new Value(); } "
			+ "function main():Int { var h = new Holder(); return h.value != null && h.copy.x == 1 ? h.value.x : 0; }");
		var initializerRejected = false;
		try initializer.compile("Main") catch (error:CompileError) initializerRejected = error.diagnostic.code == "E1005";
		if (!initializerRejected) throw "effectful struct field initializer preserved a nullable field refinement";
		// The generic origin stays unchanged while its specialization depends on the representation of Point.
		// Both directions must discard invalidated bodies, including their optional-value helpers and closures.
		var transition = new Compiler();
		var pointBody = " Point { public final x:Int; public function new(x:Int) this.x = x; }";
		transition.update("Point.hx", "@:structural struct" + pointBody);
		transition.update("Holder.hx", "class Holder { public var value:Null<Point>; public function new() value = new Point(7); "
			+ "public function invoke():Int { var f:Null<Point>->Int = function(v:Null<Point>) return v == null ? 0 : v.x; return f(value); } }");
		transition.update("Generic.hx", "class Generic { public static function keep<T>(v:T):T { var f:T->T = function(x:T) return x; return f(v); } public static function box<T>(v:T):Dynamic return v; }");
		transition.update("Main.hx", "function main():Int { var h = new Holder(); var p:Null<Point> = Generic.keep(h.value); "
			+ "var d:Dynamic = Generic.box(p); var empty:Null<Point> = null; var absent:Null<Point> = Generic.keep(empty); "
			+ "return (p == null ? 0 : p.x) + h.invoke() + (absent == null ? 1 : 0); }");
		if (new IrInterpreter(transition.compile("Main").ir).run("main") != 15) throw "initial generic optional value failed";
		transition.update("Point.hx", "@:structural class" + pointBody);
		if (new IrInterpreter(transition.compile("Main").ir).run("main") != 15) throw "struct-to-class retained an obsolete specialization";
		transition.update("Point.hx", "@:structural struct" + pointBody);
		if (new IrInterpreter(transition.compile("Main").ir).run("main") != 15) throw "class-to-struct retained an obsolete specialization";
		Sys.println("PASS: inline optional fields follow incremental method and layout edits");
	}
}
