import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles language features required by the self-hosted FFI implementation. */
class LanguageFeaturesMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"enum Value { Number(value:Int); Empty; }\n"
			+ "class Constants { public static final names = ['a', 'b']; }\n"
			+ "function main():Int {\n"
			+ "  var bits = 1; bits |= 2; bits &= 3; bits ^= 1; bits *= 4; bits %= 5; var fraction = 8.0; fraction /= 2;\n"
			+ "  var recovered = try [0][1] catch (_:Dynamic) 4;\n"
			+ "  var input:Value = Number(22); var selected = switch input { case Number(20) | Number(22): 6; case _: 0; };\n"
			+ "  var flat = [for (left in [1, 2]) for (right in [10, 20]) left + right];\n"
			+ "  var found = Lambda.find(flat, value -> value == 22);\n"
			+ "  return bits + Std.int(fraction) + recovered + selected + (flat.length == 4 && flat.contains(22) && found == 22 ? 25 : 0)"
			+ "    + (Constants.names.length == 2 && 'ffi'.toUpperCase() == 'FFI' && Math.min(2, 3) == 2 && Math.max(2, 3) == 3 ? 0 : -100);\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
