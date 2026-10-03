import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class ArrayLookupContextMain {
	static final valid = 'function main():Int { var values:Array<a.Expected> = [a.Expected.Present]; if (values.indexOf(Present) != 0 || !values.contains(Present)) return 1; return 42; }';

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("a/Expected.hx", "package a; enum Expected { Present; Absent; }");
		result.update("b/Other.hx", "package b; enum Other { Present; }");
		return result;
	}

	static function run(result:Compiler, source:String):Void {
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "array lookup lost enum element context";
	}

	static function main():Void {
		var result = compiler();
		run(result, valid);
		run(result, "import b.Other; " + valid);
		for (method in ["indexOf", "contains"]) {
			var invalid = StringTools.replace(valid, method + "(Present)", method + "(b.Other.Present)");
			for (candidate in [result, compiler()]) {
				candidate.update("Main.hx", invalid);
				var rejected = false;
				try
					candidate.compile("Main")
				catch (error:CompileError) {
					if (error.diagnostic.code != "E1002")
						throw error;
					rejected = true;
				}
				if (!rejected)
					throw "array lookup accepted an unrelated enum";
			}
		}
		run(result, valid);
		Sys.println("PASS: array indexOf/contains contextual enum typing, runtime and incremental rejection");
	}
}
