import compiler.Compiler;
import compiler.runtime.RuntimeNatives;

/** Covers Haxe function-type argument labels and inferred collection constructors. */
class FunctionTypeSyntaxMain {
	static function main():Void {
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.update("Main.hx",
			"class Collections {\n"
			+ "  var values:Array<Int>;\n"
			+ "  var entries:Map<String,Int>;\n"
			+ "  public function new() { values = new Array(); entries = new Map(); }\n"
			+ "}\n"
			+ "function apply(callback:(value:Int)->Int):Int return callback(41);\n"
			+ "function acceptsOptional(callback:(?value:Int)->Int):Void {}\n"
			+ "function main():Int { var collections = new Collections(); return apply(value -> value + 1); }");
		compiler.analyze("Main");
		Sys.println("PASS: named and optional function types and inferred collection constructors");
	}
}
