import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Exercises the forwarded read surface and rejects writes at type-check time. */
class ReadOnlyArrayMain {
	static function main():Void {
		reject('values.push(3)');
		reject('values[0] = 3');
		reject('values.splice(0, 1)');
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", 'import haxe.ds.ReadOnlyArray;
function main():Int {
  var source:Array<Int> = [10, 20, 30];
  var values:ReadOnlyArray<Int> = source;
  if (values.length != 3 || values[1] != 20 || values.indexOf(30) != 2) return 1;
  var total = 0;
  for (value in values) total += value;
  if (total != 60 || values.join(",") != "10,20,30") return 2;
  return 42;
}');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}

	static function reject(statement:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxe.ds.ReadOnlyArray; function main():Int { var values:ReadOnlyArray<Int> = [1, 2]; ' + statement + '; return 42; }');
		try {
			compiler.compile("Main");
			throw 'ReadOnlyArray accepted mutation: $statement';
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1007" && error.diagnostic.code != "E1015")
				throw error;
		}
	}
}
