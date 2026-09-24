import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxLifetimeMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			projectionPath = Sys.args()[2],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Widget.hx", File.getContent(projectionPath));
		compiler.update("Main.hx",
			"import Widget; function main():Int { var widget = Widget.create(21); var value = widget.value(); widget.close(); widget.close(); return value == 21 && widget.isClosed() && Widget.destroyed() == 1 ? 42 : 1; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
