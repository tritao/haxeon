import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class NativeKitCxxMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			projectionPath = Sys.args()[2],
			functionsPath = Sys.args()[3],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("DisplayList.hx", File.getContent(projectionPath));
		compiler.update("NativeKitDisplayListFunctions.hx", File.getContent(functionsPath));
		compiler.update("Main.hx",
			'import NativeKitDisplayList; import DisplayList; import NativeKitDisplayListFunctions; function main():Int { var list = DisplayList.fromNative(NativeKitDisplayListFunctions.haxeon_display_list_acquire()); list.reset(); return list.size() == 0 ? 42 : 1; }');
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
