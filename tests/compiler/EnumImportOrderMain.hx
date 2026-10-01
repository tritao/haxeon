import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class EnumImportOrderMain {
	static final forward = 'import a.First; import b.Second; function main():Int { var value = Item; return value == b.Second.Item ? 7 : 0; }';
	static final reverse = 'import b.Second; import a.First; function main():Int { var value = Item; return value == a.First.Item ? 9 : 0; }';

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("a/First.hx", "package a; enum First { Item; }");
		result.update("b/Second.hx", "package b; enum Second { Item; }");
		return result;
	}

	static function run(result:Compiler, source:String, expected:Int):Void {
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != expected)
			throw "wrong imported enum constructor";
	}

	static function main():Void {
		var result = compiler();
		run(result, forward, 7);
		run(result, reverse, 9);
		run(compiler(), reverse, 9);
		run(result, forward, 7);
		// An explicit expected enum still wins over the imported default.
		run(result, 'import a.First; import b.Second; function main():Int { var value:a.First = Item; return value == a.First.Item ? 5 : 0; }', 5);
		result.update("Main.hx",
			'import a.First; import b.Second; function accept(value:a.First):Int return 0; function main():Int { var value = Item; return accept(value); }');
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1009")
				throw error;
			Sys.println("PASS: enum import order, expected type priority, nominal rejection, runtime, and incremental edits");
			return;
		}
		throw "incompatible imported enum accepted";
	}
}
