import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;
import sys.io.File;

class GenericCallableAbiMain {
	static function run(result:Compiler, source:String, expected:Int):Void {
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != expected)
			throw "generic callable ABI execution disagrees";
	}

	static function reject(result:Compiler, source:String, code:String):Void {
		result.update("Main.hx", source);
		var rejected = false;
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != code)
				throw error;
			rejected = true;
		}
		if (!rejected)
			throw "incompatible generic callable was accepted";
	}

	static function main():Void {
		var source = File.getContent("tests/programs/generic-callable-abi.hx");
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		run(result, source, 42);
		run(result, StringTools.replace(source, "value + 0.5", "value + 1.5"), 6);
		run(result, source, 42);
		for (candidate in [result, new Compiler(null, CompilerIntrinsics.configuration())]) {
			reject(candidate, StringTools.replace(source, "Functions.optional(true)", "function(left:String, right:String):Bool return left == right"),
				"E1003");
			reject(candidate, StringTools.replace(source, "integers.operation = value -> value + 3", 'integers.operation = value -> "wrong"'), "E1003");
		}
		run(result, source, 42);
		Sys.println("PASS: generic callable ABI, nullable/evaluation semantics and cold/incremental rejection");
	}
}
