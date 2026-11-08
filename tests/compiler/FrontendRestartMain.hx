import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A module found only while typing restarts the frontend, and every restart is reported with its kind:
 * - `declared`: the declarations show a module that changes a representation (a class field of a specialized map type), found
 *   before any body is typed, so nothing is typed twice;
 * - `continued`: a body needs a module that functions only call (arithmetic on a Dynamic needs `haxeon.DynamicOps`); what was
 *   typed is kept and the next pass types only the new module;
 * - `representation`: a module that changes a representation was found only in a body (a specialized map met in `main`), so the
 *   declarations did not show it and everything is typed again.
 * A Dynamic object literal does not cause one on HashLink, whose dynamic objects are native.
 */
class FrontendRestartMain {
	static final value = "struct Value { public var number:Int; public function new(number:Int) this.number = number; } ";

	static function main():Void {
		var literal = compile("function keep(value:Dynamic):Void {} function main():Int { keep({count: 42}); return 42; }");
		if (literal.metrics.frontendRestarts.length != 0)
			throw 'A Dynamic object literal restarted the frontend: ${literal.metrics.frontendRestarts}';

		var arithmeticSource = "function read(value:Dynamic):Int return value < 0 ? 0 : 42; function main():Int return read(1);";
		var arithmetic = compile(arithmeticSource);
		expectReasons(arithmetic, ["continued: Main.read needs haxeon.DynamicOps"], "Dynamic arithmetic");
		var passes = arithmetic.metrics.frontendPassFunctions;
		// The second pass types the functions of the new module and nothing else: with the module imported they are the program's
		// own function (`main`) and the module's.
		var moduleAlone = compile("import haxeon.DynamicOps; function main():Int return 42;").metrics.frontendPassFunctions;
		if (passes.length != 2 || moduleAlone.length != 1 || passes[1] != moduleAlone[0] - 1)
			throw 'Dynamic arithmetic must continue with only the new module, not type everything again: typed $passes, the module alone ${moduleAlone}';
		expectSameProgram(arithmetic, compile("import haxeon.DynamicOps; " + arithmeticSource), "Dynamic arithmetic");

		var fieldSource = value
			+ "class Holder { public var entries:Map<Int, Value>; public function new() {} } "
			+ "function main():Int { var holder = new Holder(); return holder == null ? 1 : 42; }";
		var field = compile(fieldSource);
		expectReasons(field, ["declared: $type-dependency:Holder needs haxeon.collections.HashMap"], "A specialized map field");
		if (field.metrics.frontendPassFunctions.length != 1)
			throw 'A specialized map field must be typed once: typed ${field.metrics.frontendPassFunctions}';
		expectSameProgram(field, compile("import haxeon.collections.HashMap; " + fieldSource), "A specialized map field");

		var bodySource = value
			+
			"function main():Int { var entries = new Map<Int, Value>(); entries.set(1, new Value(42)); var found = entries.get(1); return found == null ? 1 : found.number; }";
		var body = compile(bodySource);
		expectReasons(body, ["representation: main needs haxeon.collections.HashMap"], "A specialized map met in a body");
		var bodyImported = compile("import haxeon.collections.HashMap; " + bodySource);
		var bodyPasses = body.metrics.frontendPassFunctions;
		if (bodyPasses.length != 2
			|| bodyImported.metrics.frontendPassFunctions.length != 1
			|| bodyPasses[1] != bodyImported.metrics.frontendPassFunctions[0])
			throw 'A representation found in a body must type the whole program again: typed $bodyPasses, with the module ${bodyImported.metrics.frontendPassFunctions}';
		expectSameProgram(body, bodyImported, "A specialized map met in a body");
		Sys.println("PASS: frontend restarts are reported by kind: declared, continued, and representation");
	}

	static function compile(source:String):compiler.Compiler.CompileResult {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", source);
		return compiler.compile("Main", null, false);
	}

	static function expectReasons(result:compiler.Compiler.CompileResult, expected:Array<String>, label:String):Void {
		var reasons = result.metrics.frontendRestarts;
		if (reasons.join("|") != expected.join("|"))
			throw '$label must restart as $expected: $reasons';
	}

	/** The program does not depend on how the module got there: the same functions and objects as with the module imported. */
	static function expectSameProgram(incremental:compiler.Compiler.CompileResult, imported:compiler.Compiler.CompileResult, label:String):Void {
		var left = shape(incremental), right = shape(imported);
		if (left != right)
			throw '$label differs from a compile that starts with the module:\n$left\n--\n$right';
		if (GeneratedProgramRunner.exitCode(incremental) != 42)
			throw '$label changed behavior';
	}

	static function shape(result:compiler.Compiler.CompileResult):String {
		var names = [for (fn in result.ir.functions) fn.name];
		names.sort(Reflect.compare);
		var objects = [
			for (object in result.ir.objects) object.name + ":" + [for (field in object.fields) field.name].join(",")
		];
		objects.sort(Reflect.compare);
		return names.join("\n") + "\n#\n" + objects.join("\n");
	}
}
