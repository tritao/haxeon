import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** Constants substituted for omitted arguments must invalidate callers even without editor semantic indexes. */
class InlineDefaultArgumentMain {
	static function main():Void {
		for (indexed in [false, true]) {
			check(indexed, "static method", "class Api { public static function read(value:Int = Constants.VALUE):Int return value; }", "Api.read()");
			check(indexed, "instance method", "class Api { public function new() {} public function read(value:Int = Constants.VALUE):Int return value; }",
				"new Api().read()");
			check(indexed, "constructor", "class Api { public var value:Int; public function new(value:Int = Constants.VALUE) this.value = value; }",
				"new Api().value");
			check(indexed, "function", "function read(value:Int = Constants.VALUE):Int return value;", "Api.read()");
			check(indexed, "generic function", "function read<T>(unused:T, value:Int = Constants.VALUE):Int return value;", "Api.read(0)");
			check(indexed, "coerced expression", "function read(value:Float = Constants.VALUE + 1):Int return value > 2.5 ? 2 : 1;", "Api.read()");
		}
		checkRemovedDependency();
		Sys.println("PASS: inline constants in default arguments invalidate cached callers");
	}

	static function constants(value:Int):String
		return 'class Constants { public static inline var VALUE:Int = $value; }';

	static function check(indexed:Bool, label:String, api:String, call:String):Void {
		var compiler = new Compiler();
		compiler.update("Constants.hx", constants(1));
		compiler.update("Api.hx", "import Constants; " + api);
		compiler.update("Main.hx", 'function main():Int return $call;');
		var first = compiler.compile("Main", null, indexed);
		if (new IrInterpreter(first.ir).run("main") != 1)
			throw '$label (indexed=$indexed): wrong initial default';
		compiler.update("Constants.hx", constants(2));
		var changed = compiler.compile("Main", null, indexed);
		if (changed.retyped.indexOf("main") < 0 || new IrInterpreter(changed.ir).run("main") != 2)
			throw '$label (indexed=$indexed): retained stale default; retyped=${changed.retyped}';
		if (compiler.compile("Main", null, indexed).retyped.length != 0)
			throw '$label (indexed=$indexed): no-op compilation retyped functions';
	}

	static function checkRemovedDependency():Void {
		var compiler = new Compiler();
		compiler.update("Constants.hx", constants(1));
		compiler.update("Api.hx", "import Constants; function read(value:Int = Constants.VALUE):Int return value;");
		compiler.update("Main.hx", "function main():Int return Api.read();");
		compiler.compile("Main", null, false);
		compiler.update("Main.hx", "function main():Int return Api.read(7);");
		compiler.compile("Main", null, false);
		compiler.update("Constants.hx", constants(2));
		var changed = compiler.compile("Main", null, false);
		if (changed.retyped.indexOf("main") >= 0 || new IrInterpreter(changed.ir).run("main") != 7)
			throw "an explicit argument retained the removed inline constant dependency";
	}
}
