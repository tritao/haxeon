import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles exception construction, chaining, throwing, catching, and inspection. */
class ExceptionMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"import haxe.Exception; import haxe.ValueException; import haxe.CallStack;\n"
			+ "function identity(value:Any):Any return value;\n"
			+ "class SampleException extends Exception { public function new(message:String) { super(message); } }\n"
			+
			"function checkSample():Bool { try { throw new SampleException('sample'); } catch (error:SampleException) { return error.message == 'sample'; } }\n"
			+ "function main():Int {\n"
			+ "  var root = new Exception('root');\n"
			+ "  try { throw new ValueException(42, root); }\n"
			+ "  catch (error:ValueException) {\n"
			+
			"    return identity(42) == 42 && checkSample() && error.value == 42 && error.message == '42' && error.previous != null && error.previous.message == 'root'"
			+ " && error.stack.length == 0 && error.details() == '42' && CallStack.exceptionStack().length == 0 ? 42 : 0;\n"
			+ "  }\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
