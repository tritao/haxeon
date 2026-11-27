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

	static final inner = "struct Inner { public final a:Int = 0; }";

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("Shapes.hx", library);
		result.update("Pair.hx", "struct Pair { public final a:Int; public final b:Int = 2; }");
		result.update("Built.hx", "struct Built { public final a:Int; public function new(a:Int) this.a = a; }");
		result.update("Inner.hx", inner);
		result.update("Outer.hx", "struct Outer { public final inner:Null<Inner> = null; public final x:Int; }");
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

	/** A struct with a constructor of its own has no synthesized `with`. */
	static function rejectOwnConstructor(result:Compiler):Void {
		result.update("Main.hx", "function main():Int return new Built(1).with(a: 2).a;");
		try {
			result.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf("with") < 0)
				throw 'unexpected diagnostic for `with` on a struct with a constructor: ${error.diagnostic.message}';
			return;
		}
		throw "`with` on a struct with its own constructor was accepted";
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
			reject(candidate, "new Pair(1).with(3).a", "takes the fields it replaces by name");
			reject(candidate, "new Pair(1).with(c: 3).a", 'has no parameter named "c"');
			reject(candidate, "new Pair(1).with(b: 3, a: 4).a", "in the order they are declared");
			reject(candidate, "new Pair(b: 3).a", 'skips the required parameter "a"');
			rejectOwnConstructor(candidate);
		}
		// A parameter's name is part of its function's signature: renaming it breaks a caller that names it.
		accept(result);
		result.update("Shapes.hx", StringTools.replace(library, "scale", "factor"));
		reject(result, "Shapes.area(2, scale: 7) == 42 ? 42 : 1", 'has no parameter named "scale"');
		result.update("Shapes.hx", library);
		accept(result);
		// A struct holding a native-layout one has no memberwise constructor, and loses it when one it holds becomes so.
		result.update("Main.hx", "function main():Int return new Outer(x: 42).x;");
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "memberwise construction of a struct holding another failed";
		result.update("Inner.hx", "struct Inner { public final a:UInt8 = 0; }");
		reject(result, "new Outer(x: 42).x", "expects 0 arguments");
		result.update("Inner.hx", inner);
		accept(result);
		// `scale:` passes the variable `scale`, which must exist.
		var short = compiler();
		short.update("Main.hx", "function main():Int { var scale = 7; return Shapes.area(2, scale:) == 42 ? 42 : 1; }");
		if (GeneratedProgramRunner.exitCode(short.compile("Main")) != 42)
			throw "a named argument's short form did not pass its variable";
		short.update("Main.hx", "function main():Int return Shapes.area(2, scale:);");
		try {
			short.compile("Main");
			throw "a short named argument without its variable was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf("scale") < 0)
				throw 'unexpected diagnostic for a short named argument: ${error.diagnostic.message}';
		}
		Sys.println("PASS: named arguments bind, pass a variable by its name alone, reject misuse cold and incrementally, and follow parameter renames");
	}
}
