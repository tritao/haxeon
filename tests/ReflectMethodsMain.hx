import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.RuntimeNatives;
import sys.io.File;

/** Compiles method-identity checks against HashLink's closure semantics. */
class ReflectMethodsMain {
	static function main():Void {
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.update("Main.hx",
			"class Handler {\n"
			+ "  var delta:Int;\n"
			+ "  public function new(delta:Int) this.delta = delta;\n"
			+ "  public function apply(value:Int):Int return value + delta;\n"
			+ "}\n"
			+ "function increment(value:Int):Int return value + 1;\n"
			+ "function decrement(value:Int):Int return value - 1;\n"
			+ "function main():Int {\n"
			+ "  var first = new Handler(1);\n"
			+ "  var second = new Handler(1);\n"
			+ "  if (!Reflect.compareMethods(increment, increment)) return 1;\n"
			+ "  if (Reflect.compareMethods(increment, decrement)) return 2;\n"
			+ "  if (!Reflect.compareMethods(first.apply, first.apply)) return 3;\n"
			+ "  if (Reflect.compareMethods(first.apply, second.apply)) return 4;\n"
			+ "  return 42;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
