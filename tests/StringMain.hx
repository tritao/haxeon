import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

class StringMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.registerNative("trace", "std", "sys_print", [CompilerType.TString], CompilerType.TVoid);
		compiler.update("Main.hx",
			'function main():Int { var text = "hello " + "world"; trace(text); if (text == "hello world") return text.length + 31; return 0; }');
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
