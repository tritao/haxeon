import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxHxiCallMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			projectionPath = Sys.args()[2],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("DisplayList.hx", File.getContent(projectionPath));
		compiler.update("Main.hx",
			"import CxxFixture; import DisplayList; function main():Int { var list = DisplayList.fromNative(CxxFixture.__cxx_nkui__acquire()); list.reset(); CxxFixture.__cxx_nkui__mark(list.nativeHandle()); return list.size() == 1 && DisplayList.make(21) == 42 && CxxFixture.__cxx_nkui__score(list.nativeHandle()) == 42 ? 42 : 1; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
