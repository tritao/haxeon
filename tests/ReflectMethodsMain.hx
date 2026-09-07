import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles method-identity checks against HashLink's closure semantics. */
class ReflectMethodsMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"class Handler {\n"
			+ "  var delta:Int;\n"
			+ "  public function new(delta:Int) this.delta = delta;\n"
			+ "  public function apply(value:Int):Int return value + delta;\n"
			+ "  public function callback():(value:Int)->Int return apply;\n"
			+ "}\n"
			+ "function increment(value:Int):Int return value + 1;\n"
			+ "function decrement(value:Int):Int return value - 1;\n"
			+ "function remove(callbacks:Array<(value:Int)->Int>, callback:(value:Int)->Int):Bool {\n"
			+ "  for (index in 0...callbacks.length) if (Reflect.compareMethods(callbacks[index], callback)) { callbacks.splice(index, 1); return true; }\n"
			+ "  return false;\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  var first = new Handler(1);\n"
			+ "  var second = new Handler(1);\n"
			+ "  if (!Reflect.compareMethods(increment, increment)) return 1;\n"
			+ "  if (Reflect.compareMethods(increment, decrement)) return 2;\n"
			+ "  if (!Reflect.compareMethods(first.apply, first.apply)) return 3;\n"
			+ "  if (Reflect.compareMethods(first.apply, second.apply)) return 4;\n"
			+ "  var callback = first.callback();\n"
			+ "  if (callback(41) != 42 || !Reflect.compareMethods(callback, first.apply)) return 5;\n"
			+ "  var callbacks = [callback, second.callback()];\n"
			+ "  if (!remove(callbacks, first.apply) || callbacks.length != 1 || !Reflect.compareMethods(callbacks[0], second.apply)) return 6;\n"
			+ "  return 42;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
