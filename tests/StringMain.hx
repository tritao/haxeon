import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

class StringMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.registerNative("trace", "std", "sys_print", [CompilerType.TString], CompilerType.TVoid);
		compiler.update("Main.hx", 'function main():Int { trace("hello " + "world"); return 42; }');
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
