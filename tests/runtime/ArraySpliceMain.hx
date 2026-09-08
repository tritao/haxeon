import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles Array.splice across the compiler-owned array ABI specializations. */
class ArraySpliceMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("Main.hx",
			"class Box {\n"
			+ "  public var value:Int;\n"
			+ "  public function new(value:Int) this.value = value;\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  var ints = [10, 20, 30, 40];\n"
			+ "  var removed = ints.splice(1, 2);\n"
			+ "  if (removed.length != 2 || removed[0] != 20 || removed[1] != 30 || ints.length != 2 || ints[1] != 40) return 1;\n"
			+ "  var strings = [\"a\", \"b\", \"c\"];\n"
			+ "  var middle = strings.splice(-2, 1);\n"
			+ "  if (middle[0] != \"b\" || strings.length != 2 || strings[1] != \"c\") return 2;\n"
			+ "  if (strings.splice(10, 1).length != 0 || strings.splice(0, -1).length != 0 || strings.length != 2) return 3;\n"
			+ "  var floats = [1.5, 2.5]; if (floats.splice(0, 1)[0] != 1.5) return 4;\n"
			+ "  var bools = [true, false]; if (!bools.splice(0, 1)[0]) return 5;\n"
			+ "  var boxes = [new Box(41), new Box(42)]; if (boxes.splice(1, 1)[0].value != 42 || boxes.length != 1) return 6;\n"
			+ "  var shifted = [10, 20, 30]; if (shifted.shift() != 10 || shifted.length != 2 || shifted[0] != 20) return 7;\n"
			+ "  var shiftedStrings = [\"first\", \"second\"]; if (shiftedStrings.shift() != \"first\" || shiftedStrings[0] != \"second\") return 8;\n"
			+ "  return 42;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
