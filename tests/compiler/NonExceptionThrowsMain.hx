import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.types.TypedAst.NonExceptionThrow;
import compiler.types.typing.TypingFailure;

/**
 * The typer records each `throw` whose value's static type is not haxe.Exception or a subclass of it (`TypedProgram.nonExceptionThrows`,
 * which `haxeon lint --only throw-non-exception` reports), statement or expression, and only those: a throw of an exception, a nullable
 * one, or a subclass is not one, and neither is any throw of a body whose typing failed, before the throw or after, in a function or in
 * a field initializer (which recovers in its class's output).
 */
class NonExceptionThrowsMain {
	static final program = [
		'import haxe.Exception;',
		'class Failure extends Exception {}',
		'enum Problem { Broken; }',
		'class Holder {',
		'	public var f:Int = if (Std.random(2) > 5) throw "initializer" else 1;',
		'	public function new() {}',
		'	public function method():Void throw 42;',
		'}',
		'function text():Void throw "text";',
		'function dynamicValue(value:Dynamic):Void throw value;',
		'function problem():Void throw Broken;',
		'function exception():Void throw new Exception("exception");',
		'function subclass():Void throw new Failure("subclass");',
		'function nullable(e:Null<Exception>):Void throw e;',
		'function rethrow():Void { try text() catch (e:Exception) throw e; }',
		'function rethrowAny():Void { try text() catch (e:Dynamic) throw e; }',
		'function inExpression(n:Int):Int return n > 0 ? n : throw "negative";',
		'function exceptionInExpression(n:Int):Int return n > 0 ? n : throw new Failure("negative");',
		'function inLambda():Void { var f = () -> throw "lambda"; f(); }',
		'function main():Void { trace(new Holder().f); }'
	].join("\n");

	static final failing = [
		'class Box {',
		'	public var f:Int = { if (Std.random(2) > 5) throw "failed initializer"; var m = new Map(); 1; };',
		'	public var g:Int = if (Std.random(2) > 5) throw "good initializer" else 1;',
		'	public function new() {}',
		'}',
		'function kept():Void throw "kept";',
		'function failsEarly():Void { var s:String = 1; throw "early"; }',
		'function failsLate():Void { throw "late"; var m = new Map(); }',
		'function main():Void { kept(); failsEarly(); failsLate(); trace(new Box().f); }'
	].join("\n");

	static function main():Void {
		expect("typed program", lines(analyze(program)), [
			"5: String", "7: Int", "9: String", "10: Dynamic", "11: Problem", "16: Dynamic", "17: String", "19: String"
		]);
		var failure:Null<TypingFailure> = null;
		var c = compiler();
		c.update("Main.hx", failing);
		try {
			c.analyze("Main");
		} catch (error:TypingFailure) {
			failure = error;
		} catch (error:CompileError) {
			throw 'The failing program failed outside its bodies: ${error.formatAll()}';
		}
		if (failure == null)
			throw "The failing program typed";
		if (failure.diagnostics.length != 3)
			throw 'Expected three failed bodies, got: ${failure.formatAll()}';
		expect("failed program", lines(failure.nonExceptionThrows), ["3: String", "6: String"]);
		Sys.println("PASS: the typer records the throws of a non-exception, and none of a failed body");
	}

	static function compiler():Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		return c;
	}

	static function analyze(source:String):Array<NonExceptionThrow> {
		var c = compiler();
		c.update("Main.hx", source);
		return c.analyze("Main").nonExceptionThrows;
	}

	/** `line: type` of each throw, once each, in line order: a body typed twice (a specialization) records its throws twice. */
	static function lines(throws:Array<NonExceptionThrow>):Array<String> {
		var result:Array<String> = [];
		for (thrown in throws) {
			var line = '${thrown.span.file.lineColumnAt(thrown.span.start).line}: ${thrown.thrown}';
			if (result.indexOf(line) < 0)
				result.push(line);
		}
		result.sort((left, right) -> Std.parseInt(left.split(":")[0]) - Std.parseInt(right.split(":")[0]));
		return result;
	}

	static function expect(label:String, actual:Array<String>, expected:Array<String>):Void
		if (actual.join(", ") != expected.join(", "))
			throw '$label: expected non-exception throws [${expected.join(", ")}], got [${actual.join(", ")}]';
}
