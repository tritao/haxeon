import compiler.Compiler;
import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;

/** Covers Haxe function-type argument labels and inferred collection constructors. */
class FunctionTypeSyntaxMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("Main.hx",
			"class Collections {\n"
			+ "  var values:Array<Int>;\n"
			+ "  var labels:List<String>;\n"
			+ "  var entries:Map<String,String>;\n"
			+ "  public function new() { values = new Array(); labels = new List(); entries = new Map(); }\n"
			+ "  public function clear() values = [];\n"
			+ "  public function choose(flag:Bool) { try { if (flag) return true; return false; } catch (error:Dynamic) { return false; } }\n"
			+ "  public function get(name:String) return entries.get(name);\n"
			+ "  public function iterator() return labels.iterator();\n"
			+ "}\n"
			+ "function apply(callback:(value:Int)->Int):Int return callback(41);\n"
			+ "function acceptsOptional(callback:(?value:Int)->Int):Void {}\n"
			+ "function main():Int { var collections = new Collections(); return apply(value -> value + 1); }");
		compiler.analyze("Main");
		Sys.println("PASS: named and optional function types and inferred collection constructors");
		expectValue("typed lambda local", "function main():Int { var read = function(value:Int):Int return value + 1; return read(41); }");
		expectValue("typed lambda block body", "function main():Int { var read = function(value:Int):Int { return value + 1; }; return read(41); }");
		expectValue("typed lambda without arguments", "function main():Int { var read = function():Int return 42; return read(); }");
		expectValue("typed lambda argument",
			"function apply(callback:Int->Int):Int return callback(41); function main():Int return apply(function(value:Int):Int return value + 1);");
		expectValue("typed lambda capture",
			"enum Mode { On; Off; } function main():Int { var mode = On; var base = 40; var read = function(value:Int):Int return mode == On ? base + value : 0; return read(2); }");
		expectValue("two typed lambdas",
			"function main():Int { var a = function(value:Int):Int return value + 1; var b = function(value:Int):Int return value * 2; return b(a(20)); }");
		var mismatch = false;
		try {
			Frontend.compile('function main():Int { var read = function(value:Int):Int return "text"; return read(1); }');
		} catch (error:CompileError)
			mismatch = true;
		if (!mismatch)
			throw "A typed lambda accepted a body that does not match its declared result";
		Sys.println("PASS: function expressions with declared result types");
	}

	static function expectValue(label:String, source:String):Void {
		var value = new IrInterpreter(Frontend.compile(source)).run("main");
		if (value != 42)
			throw '$label returned $value instead of 42';
	}
}
