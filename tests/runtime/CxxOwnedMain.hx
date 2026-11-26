using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxOwnedMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			projectionDirectory = Sys.args()[2],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("OwnedWidget.hx", File.getContent(projectionDirectory + "/OwnedWidget.hx"));
		compiler.update("Widget.hx", File.getContent(projectionDirectory + "/Widget.hx"));
		compiler.update("CxxOwnedFixtureFunctions.hx",
			File.getContent(projectionDirectory + "/CxxOwnedFixtureFunctions.hx"));
		compiler.update("Main.hx", File.getContent(Sys.getCwd() + "/tests/runtime/CxxOwnedProgram.hx"));
		File.saveBytes(output, compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten());
	}
}
