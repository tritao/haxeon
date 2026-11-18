import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/**
 * Typing recovers from a failed body: it records the error, leaves the body out and types the next one, then fails with one error
 * per failed body, in the order the bodies were typed, and none caused by another failed body. A compiler that failed this way
 * builds the fixed program, warm or fresh.
 */
class TypingRecoveryMain {
	static final broken = [
		'class Box {',
		'	public var a:Int = "no";',
		'	public var b:Int = 3;',
		'	public static var c = missingThing + 1;',
		'	public static var d = [c];',
		'	public function new() {}',
		'	public function bad():Int return "x";',
		'	public function good():Int return b + first();',
		'}',
		'abstract Meters(Int) {',
		'	public static function parse(text:String):Int return text;',
		'}',
		'function identity<T>(value:T):T { var wrong:Bool = 1; return value; }',
		'function first():Int { var later = []; later.push(1); var s:String = 1; return later[0]; }',
		'function second():String { return undefinedThing; }',
		'function third():Int { var m = new Map(); return 1; }',
		'function usesFirst():Int return first() + identity(1);',
		'function usesIdentity():Int return identity(2);',
		'function readsC():Int { var c:Int = Box.c; return c + Box.d.length; }',
		'function main():Int { var x:Bool = 5; return usesFirst() + usesIdentity() + readsC(); }'
	].join("\n");

	static final fixed = [
		'class Box {',
		'	public var a:Int = 1;',
		'	public var b:Int = 3;',
		'	public static var c = 1 + 1;',
		'	public static var d = [c];',
		'	public function new() {}',
		'	public function bad():Int return 2;',
		'	public function good():Int return b + first();',
		'}',
		'abstract Meters(Int) {',
		'	public static function parse(text:String):Int return text.length;',
		'}',
		'function identity<T>(value:T):T { var right:Bool = true; return value; }',
		'function first():Int { var later = []; later.push(1); var s:String = "1"; return later[0]; }',
		'function second():String { return "thing"; }',
		'function third():Int { var m = new Map<String, Int>(); return 1; }',
		'function usesFirst():Int return first() + identity(1);',
		'function usesIdentity():Int return identity(2);',
		'function readsC():Int { var c:Int = Box.c; return c + Box.d.length; }',
		'function main():Int { var box = new Box(); return 27 + usesFirst() + usesIdentity() + readsC() + box.good() + box.bad() + Meters.parse("ab"); }'
	].join("\n");

	/**
	 * Line and code of each expected error, in typing order: field initializers, method bodies, module functions, abstract statics.
	 * The unannotated field Box.c fails once; Box.d and readsC read it as Dynamic and report nothing.
	 */
	static final expected = [
		"2:E1002", // Box.a
		"4:E1005", // Box.c
		"7:E1003", // Box.bad
		"13:E1002", // identity, typed with T as itself; identity<Int>, typed for usesFirst and usesIdentity, is not reported again
		"14:E1002", // first
		"15:E1005", // second
		"16:E1003", // third: a map nothing fixes
		"20:E1002", // main
		"11:E1003" // Meters.parse
	];

	static function compiler():Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		return c;
	}

	static function errors(c:Compiler, source:String):Array<String> {
		c.update("Main.hx", source);
		try {
			c.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostics[0] != error.diagnostic)
				throw "The first diagnostic of a failure is not its own";
			return [
				for (diagnostic in error.diagnostics)
					diagnostic.span.file.lineColumnAt(diagnostic.span.start).line + ":" + diagnostic.code
			];
		}
		throw "A program with errors in its bodies compiled";
	}

	static function check(label:String, actual:Array<String>):Void
		if (actual.join(",") != expected.join(","))
			throw '$label: expected errors ${expected.join(",")}, got ${actual.join(",")}';

	static function main():Void {
		check("fresh", errors(compiler(), broken));
		var warm = compiler();
		check("warm, first build", errors(warm, broken));
		warm.update("Main.hx", fixed);
		var exit = GeneratedProgramRunner.exitCode(warm.compile("Main"));
		if (exit != 42)
			throw 'The fixed program, built warm after the failed one, returned $exit';
		check("warm, broken again", errors(warm, broken));
		var fresh = compiler();
		fresh.update("Main.hx", fixed);
		if (GeneratedProgramRunner.exitCode(fresh.compile("Main")) != 42)
			throw "The fixed program, built fresh, did not return 42";
		Sys.println("PASS: typing recovers from failed bodies, reports each once and builds the fixed program warm and fresh");
	}
}
