import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

class ArrayMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.registerNative("array_int_alloc", "haxeon_runtime", "array_int_alloc", [CompilerType.TInt], CompilerType.TArray(CompilerType.TInt));
		compiler.update("Main.hx",
			"function main():Int { var values:Array<Int> = array_int_alloc(2); values[0] = 40; values[1] = 2; return values[0] + values.length; }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
