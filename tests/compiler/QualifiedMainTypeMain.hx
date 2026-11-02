import compiler.Compiler;
import compiler.ir.IrInterpreter;

class QualifiedMainTypeMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("pkg/Widget.hx", "package pkg; class Widget { public var value:Int; public function new(value:Int) this.value=value; } "
			+ "class Extra { public var value:Int; public function new(value:Int) this.value=value; }");
		compiler.update("Main.hx", "function read(value:pkg.Widget.Widget, extra:pkg.Widget.Extra):Int return value.value + extra.value; "
			+ "function main():Int return read(new pkg.Widget.Widget(20), new pkg.Widget.Extra(22));");
		var first = compiler.compile("Main");
		if (new IrInterpreter(first.ir).run("main") != 42) throw "Fully qualified module declarations did not resolve";
		compiler.update("pkg/Widget.hx", "package pkg; class Widget { public var value:Int; public function new(value:Int) this.value=value+1; } "
			+ "class Extra { public var value:Int; public function new(value:Int) this.value=value; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 43) throw "Qualified type dependency was not refreshed";
		Sys.println("PASS: fully qualified primary and secondary module types resolve incrementally");
	}
}
