import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

class ImportMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("editor/util/Math.hx", "package editor.util; function add(a:Int, b:Int):Int { return a + b; }");
		compiler.update("editor/Main.hx", "package editor; import editor.util.Math; function main():Int { return Math.add(20, 22); }");
		var result = compiler.compile("editor.Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
