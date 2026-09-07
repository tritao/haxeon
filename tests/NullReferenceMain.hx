import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Covers Haxe-compatible null values for reference-like types. */
class NullReferenceMain {
	static function main():Void {
		var compiler = configuredCompiler();
		compiler.update("Main.hx",
			"class Box {}\n"
			+ "function nullString():String return null;\n"
			+ "function nullArray():Array<Int> return null;\n"
			+ "function nullMap():Map<String,Int> return null;\n"
			+ "function nullFunction():(value:Int)->Int return null;\n"
			+ "function nullObject():Box return null;\n"
			+ "function main():Int {\n"
			+ "  var text:String = null;\n"
			+ "  return text == null && nullString() == null && nullArray() == null && nullMap() == null\n"
			+ "    && nullFunction() == null && nullObject() == null ? 42 : 1;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));

		for (primitive in ["Int", "Bool", "Float"]) {
			var rejectedPrimitive = false;
			try {
				var invalid = configuredCompiler();
				invalid.update("Invalid.hx", 'function invalid():$primitive return null; function main():Int return 0;');
				invalid.compile("Invalid");
			} catch (_:CompileError) {
				rejectedPrimitive = true;
			}
			if (!rejectedPrimitive)
				throw 'null must remain incompatible with $primitive returns';
		}
	}

	static function configuredCompiler():Compiler {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		return compiler;
	}
}
