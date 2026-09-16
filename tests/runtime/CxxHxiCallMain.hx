import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxHxiCallMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Main.hx",
			"import CxxFixture; function main():Int { var list = CxxFixture.__cxx_nkui__acquire(); CxxFixture.__cxx_nkui__DisplayList__reset(list); CxxFixture.__cxx_nkui__mark(list); return CxxFixture.__cxx_nkui__DisplayList__size(list) == 1 && CxxFixture.__cxx_nkui__DisplayList__make(21) == 42 && CxxFixture.__cxx_nkui__score(list) == 42 ? 42 : 1; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
