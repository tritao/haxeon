import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;

/** Named-argument diagnostics, cold and incremental, and a parameter rename reaching the callers that name it. */
class NamedArgumentsMain {
	static final library =
		"class Shapes {
		public static function area(width:Int, height:Int = 3, scale:Int = 1):Int return width * height * scale;
		public static function need(a:Int, b:Int, ?c:Int):Int return a + b;
	}";
	static final valid = "function main():Int return Shapes.area(2, scale: 7) == 42 ? 42 : 1;";

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("Shapes.hx", library);
		return result;
	}

	static function accept(result:Compiler):Void {
		result.update("Main.hx", valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "named-argument call execution failed";
	}

	static function reject(result:Compiler, call:String, message:String):Void {
		result.update("Main.hx", 'function main():Int return $call;');
		try {
			result.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1008" || error.diagnostic.message.indexOf(message) < 0)
				throw 'unexpected diagnostic for `$call`: ${error.diagnostic.code} ${error.diagnostic.message}';
			return;
		}
		throw 'invalid named-argument call `$call` was accepted';
	}

	static function main():Void {
		var result = compiler();
		accept(result);
		for (candidate in [result, compiler()]) {
			reject(candidate, "Shapes.area(2, depth: 3)", 'has no parameter named "depth"');
			reject(candidate, "Shapes.area(2, scale: 2, height: 3)", "in the order they are declared");
			reject(candidate, "Shapes.area(2, height: 2, height: 3)", "in the order they are declared");
			reject(candidate, "Shapes.area(2, height: 2, 4)", "follows a named one");
			reject(candidate, "Shapes.area(2, width: 3)", "is given positionally already");
			reject(candidate, "Shapes.need(1, c: 3)", 'skips the required parameter "b"');
			reject(candidate, "{ var f = Shapes.area; f(2, height: 3); }", "this call has no parameter names");
		}
		// A parameter's name is part of its function's signature: renaming it breaks a caller that names it.
		accept(result);
		result.update("Shapes.hx", StringTools.replace(library, "scale", "factor"));
		reject(result, "Shapes.area(2, scale: 7) == 42 ? 42 : 1", 'has no parameter named "scale"');
		result.update("Shapes.hx", library);
		accept(result);
		Sys.println("PASS: named arguments bind, reject misuse cold and incrementally, and follow parameter renames");
	}
}
