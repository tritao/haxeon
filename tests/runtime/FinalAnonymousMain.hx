import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Final fields on anonymous types remain read-only through nested access. */
class FinalAnonymousMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", 'typedef Frame = { final x:Float; }
	typedef Occurrence = { final pose:Frame; }
	function main():Int { var value:Occurrence = {pose: {x: 2.0}}; value.pose.x = 3.0; return 42; }');
		try {
			compiler.compile("Main");
			throw "Final anonymous field accepted mutation";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1024") throw error;
		}
		compiler.update("Main.hx", 'typedef Frame = { final x:Float; }
	function main():Int { var value:Frame = {x: 2.0}; value.x++; return 42; }');
		try {
			compiler.compile("Main");
			throw "Final anonymous field accepted increment";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1024") throw error;
		}
		compiler.update("Main.hx", 'typedef Frame = { final x:Float; }
	function main():Int { var value:Frame = {x: 2.0}; return value.x == 2.0 ? 42 : 1; }');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
