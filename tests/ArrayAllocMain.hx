import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import sys.io.File;

class ArrayAllocMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"function main():Int { var values = new Array<Int>(2); values[0] = 40; values[1] = 2; var floats = new Array<Float>(2); floats[0] = 1.5; floats[1] = 2.5; var strings = new Array<String>(1); strings[0] = \"ok\"; var flags = new Array<Bool>(2); flags[0] = 1 < 2; flags[1] = 2 < 1; return values[0] + values.length + floats.length + strings.length + flags.length; }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
