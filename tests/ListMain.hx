import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.RuntimeNatives;
import sys.io.File;

/** Compiles and executes the Array-backed List compatibility subset. */
class ListMain {
	static function main():Void {
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"function main():Int {\n"
			+ "  var values:List<Int> = new List();\n"
			+ "  var explicit = new List<Int>(); explicit.add(20);\n"
			+ "  values.add(explicit[0]); values.add(22);\n"
			+ "  var total = 0; for (value in values.iterator()) total += value;\n"
			+ "  return values.length == 2 ? total : 0;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
