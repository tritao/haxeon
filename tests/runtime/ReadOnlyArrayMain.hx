using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Exercises the forwarded read surface and rejects writes at type-check time. */
class ReadOnlyArrayMain {
	static function main():Void {
		reject('values.push(3)');
		reject('values[0] = 3');
		reject('values.splice(0, 1)');
		rejectSource('import haxe.ds.ReadOnlyArray; function main():Int { var values:ReadOnlyArray<{x:Float}> = [{x: "bad"}]; return 42; }');
		rejectSource('abstract Hidden(Array<{x:Float}>) {} function main():Int { var values:Hidden = [{x: 1}]; return 42; }');
		rejectSource('abstract MethodOnly(Array<{x:Float}>) { @:from public static function convert(value:Array<{x:Float}>):MethodOnly return cast value; } function main():Int { var values:MethodOnly = [{x: 1}]; return 42; }');
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxe.ds.ReadOnlyArray;
function main():Int {
  var source:Array<Int> = [10, 20, 30];
  var values:ReadOnlyArray<Int> = source;
  if (values.length != 3 || values[1] != 20 || values.indexOf(30) != 2) return 1;
  var total = 0;
  for (value in values) total += value;
  if (total != 60 || values.join(",") != "10,20,30") return 2;
  return 42;
}');
		File.saveBytes(Sys.args()[0], compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten());
	}

	static function rejectSource(source:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source);
		try {
			compiler.compile("Main");
			throw "Invalid abstract array conversion was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1002" && error.diagnostic.code != "E1003") throw error;
		}
	}

	static function reject(statement:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxe.ds.ReadOnlyArray; function main():Int { var values:ReadOnlyArray<Int> = [1, 2]; ' + statement
			+ '; return 42; }');
		try {
			compiler.compile("Main");
			throw 'ReadOnlyArray accepted mutation: $statement';
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1005" && error.diagnostic.code != "E1015")
				throw error;
		}
	}
}
