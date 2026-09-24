import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxVirtualMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			projectionPath = Sys.args()[2],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Renderer.hx", File.getContent(projectionPath));
		compiler.update("Main.hx",
			"import CxxVirtual; import Renderer; function main():Int { var renderer = Renderer.fromNative(CxxVirtual.__cxx_cxxvirt__acquire()); return renderer.draw(21) == 42 ? 42 : 1; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
