import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.RuntimeNatives;
import sys.io.File;

/** Compiles a representative utest-style suite with Haxeon. */
class UtestMain {
	static function main():Void {
		var arguments = Sys.args();
		var output = arguments[0];
		var source = arguments.length > 1 ? arguments[1] : "tests/programs/utest-basic.hx";
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.update("utest/Assert.hx", File.getContent("stdlib/utest/Assert.hx"));
		compiler.update("utest/Test.hx", File.getContent("stdlib/utest/Test.hx"));
		compiler.update("utest/Runner.hx", File.getContent("stdlib/utest/Runner.hx"));
		compiler.update("utest/ui/Report.hx", File.getContent("stdlib/utest/ui/Report.hx"));
		compiler.update("Main.hx", File.getContent(source));
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
