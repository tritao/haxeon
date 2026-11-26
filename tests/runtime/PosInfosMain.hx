using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Confirms call-site positions are refreshed by an incremental source edit. */
class PosInfosMain {
	static function main():Void {
		var arguments = Sys.args();
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("haxe/PosInfos.hx", File.getContent("stdlib/haxe/PosInfos.hx"));
		var source =
			"import haxe.PosInfos;\nfunction position(?pos:PosInfos):PosInfos { if (pos == null) throw \"missing\"; return pos; }\nfunction main():Int {\n\treturn position().lineNumber;\n}\n";
		compiler.update("Position.hx", source);
		var initial = compiler.compile("Position");
		File.saveBytes(arguments[0], initial.artifact.hashLink().hashLinkBytes().flatten());
		compiler.update("Position.hx", "\n" + source);
		var edited = compiler.compile("Position");
		if (edited.requiresReload || edited.artifact.hashLink().patchBytes == null
			|| edited.changedFunctions.length == 0)
			throw "moving a PosInfos call site did not produce a hot patch";
		File.saveBytes(arguments[1], edited.artifact.hashLink().hashLinkBytes().flatten());
	}
}
