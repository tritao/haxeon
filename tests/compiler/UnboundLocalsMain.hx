import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.types.TypedAst.UnboundLocal;
import compiler.types.typing.TypingFailure;

/**
 * The typer records each local whose type nothing fixed, so it settled to Dynamic (`TypedProgram.unboundLocals`, which `haxeon lint
 * --only unbound-local` reports), and only those: a local a later use fixes or hints is not one, and neither is any local of a body
 * whose typing failed, whether it failed before its locals settled or after (an unfixed `new Map()`, in a function or in a field
 * initializer, which recovers in its class's output).
 */
class UnboundLocalsMain {
	static final program = [
		'class Holder {',
		'	public var f:Int = { var inInitializer; 1; };',
		'	public var g:Int = { var fixedInInitializer; fixedInInitializer = 2; fixedInInitializer; };',
		'	public function new() {}',
		'	public function method():Int { var inMethod; return 1; }',
		'}',
		'function unassigned():Int { var x; return 1; }',
		'function emptyArray():Int { var a = []; return 1; }',
		'function nullLocal():Int { var n = null; return 1; }',
		'function assigned():Int { var y; y = 2; return y; }',
		'function pushed():Int { var b = []; b.push(1); return b[0]; }',
		'function hinted():Array<String> { var c = []; return c; }',
		'function copied():Int { var d = []; var e = d; return 1; }',
		'function inLambda():Int { var f = function() { var inner; return 1; }; return f(); }',
		'function main():Int { return unassigned() + emptyArray() + nullLocal() + assigned() + pushed() + hinted().length'
			+ ' + copied() + inLambda() + new Holder().method(); }'
	].join("\n");

	static final failing = [
		'class Box {',
		'	public var f:Int = { var inFailedInitializer; var m = new Map(); 1; };',
		'	public var g:Int = { var inGoodInitializer; 1; };',
		'	public function new() {}',
		'}',
		'function kept():Int { var keptLocal; return 1; }',
		'function failsEarly():Int { var early; var s:String = 1; return 1; }',
		'function failsLate():Int { var late; var m = new Map(); return 1; }',
		'function main():Int { return kept() + failsEarly() + failsLate() + new Box().f; }'
	].join("\n");

	static function main():Void {
		var found = names(analyze(program));
		expect("typed program", found, ["inInitializer", "inMethod", "x", "a", "n", "d", "inner"]);
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
		expect("failed program", names(failure.unboundLocals), ["inGoodInitializer", "keptLocal"]);
		// The span is the local's declaration, which a report gives the line of.
		for (local in analyze(program))
			if (local.name == "a" && local.span.file.lineColumnAt(local.span.start).line != 8)
				throw 'Local "a" is reported at the wrong place';
		Sys.println("PASS: the typer records the locals that settle to Dynamic, and none of a failed body");
	}

	static function compiler():Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		return c;
	}

	static function analyze(source:String):Array<UnboundLocal> {
		var c = compiler();
		c.update("Main.hx", source);
		return c.analyze("Main").unboundLocals;
	}

	/** The distinct names, sorted: a local whose type holds two empty variables is listed once. */
	static function names(locals:Array<UnboundLocal>):Array<String> {
		var result:Array<String> = [];
		for (local in locals)
			if (result.indexOf(local.name) < 0)
				result.push(local.name);
		result.sort(Reflect.compare);
		return result;
	}

	static function expect(label:String, actual:Array<String>, expected:Array<String>):Void {
		expected.sort(Reflect.compare);
		if (actual.join(",") != expected.join(","))
			throw '$label: expected unbound locals [${expected.join(", ")}], got [${actual.join(", ")}]';
	}
}
