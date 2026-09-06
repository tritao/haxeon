import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

class StringMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.registerNative("trace", "std", "sys_print", [CompilerType.TString], CompilerType.TVoid);
		compiler.update("Main.hx",
			'function main():Int { var text = "hello " + "world"; trace(text); var found = text.indexOf("world"); var piece = text.substring(6, 11); if (piece == "world") return text.length + found + piece.length + 20; return 0; }');
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
