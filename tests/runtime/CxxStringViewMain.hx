import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxStringViewMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			textPath = Sys.args()[2],
			functionsPath = Sys.args()[3],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Text.hx", File.getContent(textPath));
		compiler.update("cxx_viewFunctions.hx", File.getContent(functionsPath));
		compiler.update("Main.hx",
			'import cxx_view; import Text; import cxx_viewFunctions; function main():Int { var text = Text.fromNative(cxx_view.__cxx_cxxview__acquire()); var value = "hé"; return text.count(value) == 3 && cxx_viewFunctions.count(value) == 3 ? 42 : 1; }');
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
