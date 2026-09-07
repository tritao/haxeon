import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.RuntimeNatives;
import sys.io.File;

/** Compiles regex literals and the supported EReg inspection operations. */
class ERegMain {
	static function main():Void {
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"function main():Int {\n"
			+ "  var expression = ~/world/i;\n"
			+ "  if (!expression.match('hello WORLD!')) return 0;\n"
			+ "  var position = expression.matchedPos();\n"
			+ "  if (expression.matched(0) != 'WORLD' || expression.matchedLeft() != 'hello ' || expression.matchedRight() != '!') return 1;\n"
			+ "  if (position.pos != 6 || position.len != 5 || expression.replace('world world', 'x') != 'x world') return 2;\n"
			+ "  var global = ~/world/g;\n"
			+ "  if (global.replace('world world', 'x') != 'x x' || global.split('oneworldtwo').length != 2) return 3;\n"
			+ "  return 42;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
