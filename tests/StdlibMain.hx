import compiler.RuntimeAbi;
import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import sys.io.File;

/** Compiles a program against the selectively vendored Haxe standard library. */
class StdlibMain {
	static function main():Void {
		var output = Sys.args()[0];
		var compiler = new Compiler();
		RuntimeAbi.register(compiler);
		compiler.update("haxe/ds/ArraySort.hx", File.getContent("stdlib/haxe/ds/ArraySort.hx"));
		compiler.update("Main.hx",
			"import haxe.ds.ArraySort; function compare(left:Int, right:Int):Int return left - right; function main():Int { var values = [30, 10, 20, 20]; ArraySort.sort(values, compare); return values[0] + values[1] + values[2] - values[3] + 22; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
