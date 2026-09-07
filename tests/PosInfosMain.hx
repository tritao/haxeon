import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.RuntimeNatives;
import sys.io.File;

/** Confirms call-site positions are refreshed by an incremental source edit. */
class PosInfosMain {
	static function main():Void {
		var arguments = Sys.args();
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.update("haxe/PosInfos.hx", File.getContent("stdlib/haxe/PosInfos.hx"));
		var source = "import haxe.PosInfos;\nfunction position(?pos:PosInfos):PosInfos { if (pos == null) throw \"missing\"; return pos; }\nfunction main():Int {\n\treturn position().lineNumber;\n}\n";
		compiler.update("Position.hx", source);
		var initial = compiler.compile("Position");
		File.saveBytes(arguments[0], HlWriter.encode(initial.module));
		compiler.update("Position.hx", "\n" + source);
		var edited = compiler.compile("Position");
		if (edited.requiresReload || edited.patchBytes == null || edited.changedFunctions.length == 0)
			throw "moving a PosInfos call site did not produce a hot patch";
		File.saveBytes(arguments[1], HlWriter.encode(edited.module));
	}
}
