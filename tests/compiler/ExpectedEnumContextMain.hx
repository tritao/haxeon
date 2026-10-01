import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class ExpectedEnumContextMain {
	static final valid = 'import a.Expected; import b.Other; function make():a.Expected { var values = []; return Case(values); } function main():Int return switch make() { case a.Expected.Case(values): values.length + 7; };';

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("a/Expected.hx", "package a; enum Expected { Case(values:Array<Int>); }");
		result.update("b/Other.hx", "package b; enum Other { Case; }");
		return result;
	}

	static function main():Void {
		var result = compiler();
		result.update("Main.hx", valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 7)
			throw "wrong enum array context";
		var invalid = StringTools.replace(valid, "return Case(values)", 'values.push("bad"); return Case(values)');
		var cold = compiler();
		for (candidate in [result, cold]) {
			candidate.update("Main.hx", invalid);
			var rejected = false;
			try
				candidate.compile("Main")
			catch (error:CompileError) {
				if (error.diagnostic.code != "E1009")
					throw error;
				rejected = true;
			}
			if (!rejected)
				throw "wrong inferred constructor element accepted";
		}
		result.update("Main.hx", valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 7)
			throw "restored constructor context failed";
		Sys.println("PASS: expected enum constructor argument inference, runtime, rejection and incremental restoration");
	}
}
