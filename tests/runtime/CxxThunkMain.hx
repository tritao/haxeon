import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxThunkMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			counterPath = Sys.args()[2],
			functionsPath = Sys.args()[3],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Counter.hx", File.getContent(counterPath));
		compiler.update("CxxThunkFixtureFunctions.hx", File.getContent(functionsPath));
		compiler.update("Main.hx",
			"import CxxThunkFixture; import Counter; import CxxThunkFixtureFunctions; function main():Int { var counter = Counter.fromNative(CxxThunkFixture.__cxx_cxxthunk__acquire()); var value = counter.value(); var methodFailed = false; try counter.fail() catch (error:Dynamic) methodFailed = Std.string(error).indexOf(\"counter failed\") >= 0; var functionWorked = CxxThunkFixtureFunctions.add(20, 22) == 42; var functionFailed = false; try CxxThunkFixtureFunctions.add(1, 0) catch (error:Dynamic) functionFailed = Std.string(error).indexOf(\"division-like failure\") >= 0; return value == 42 && methodFailed && functionWorked && functionFailed ? 42 : 1; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
