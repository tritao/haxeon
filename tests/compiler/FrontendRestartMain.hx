import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A module found only while typing restarts the frontend, and the restarts are reported:
 * - a module that functions only call (arithmetic on a Dynamic needs `haxeon.DynamicOps`) is a continuation: what was typed is
 *   kept and the next pass types only the new module;
 * - a module that changes a representation is never found late, because the specialized map owner's module is part of every
 *   program: a class field of a specialized map type, or a specialized map met only inside a body, restarts nothing and types
 *   the program once; without it (no stdlib root) the compiler stops and names the module.
 * A Dynamic object literal does not cause a restart on HashLink, whose dynamic objects are native.
 */
class FrontendRestartMain {
	static final value = "struct Value { public var number:Int; public function new(number:Int) this.number = number; } ";

	static function main():Void {
		var literal = compile("function keep(value:Dynamic):Void {} function main():Int { keep({count: 42}); return 42; }");
		if (literal.metrics.frontendRestarts.length != 0)
			throw 'A Dynamic object literal restarted the frontend: ${literal.metrics.frontendRestarts}';

		var arithmeticSource = "function read(value:Dynamic):Int return value < 0 ? 0 : 42; function main():Int return read(1);";
		var arithmetic = compile(arithmeticSource);
		expectReasons(arithmetic, ["Main.read needs haxeon.DynamicOps"], "Dynamic arithmetic");
		var passes = arithmetic.metrics.frontendPassFunctions;
		var reports = arithmetic.metrics.frontendPassReports;
		if (reports.length != passes.length || reports[0].indexOf("pass1 graph=") != 0 || reports[1].indexOf("pass2 graph=") != 0 || reports[1].indexOf("parse-within=") < 0)
			throw 'Every frontend pass must report its stages and its parsing: $reports';
		// The second pass types the functions of the new module and nothing else: the program with the module imported types its
		// own function and the always-present map module's besides.
		var plain = compile("function main():Int return 42;").metrics.frontendPassFunctions;
		var moduleAlone = compile("import haxeon.DynamicOps; function main():Int return 42;").metrics.frontendPassFunctions;
		if (passes.length != 2 || plain.length != 1 || moduleAlone.length != 1 || passes[1] != moduleAlone[0] - plain[0])
			throw 'Dynamic arithmetic must continue with only the new module, not type everything again: typed $passes, the module alone ${moduleAlone} over ${plain}';
		expectSameProgram(arithmetic, compile("import haxeon.DynamicOps; " + arithmeticSource), "Dynamic arithmetic");

		var fieldSource = value
			+ "class Holder { public var entries:Map<Int, Value>; public function new() {} } "
			+ "function main():Int { var holder = new Holder(); return holder == null ? 1 : 42; }";
		var field = compile(fieldSource);
		expectReasons(field, [], "A specialized map field");
		if (field.metrics.frontendPassFunctions.length != 1)
			throw 'A specialized map field must be typed once: typed ${field.metrics.frontendPassFunctions}';
		expectSameProgram(field, compile("import haxeon.collections.HashMap; " + fieldSource), "A specialized map field");

		var bodySource = value
			+
			"function main():Int { var entries = new Map<Int, Value>(); entries.set(1, new Value(42)); var found = entries.get(1); return found == null ? 1 : found.number; }";
		var body = compile(bodySource);
		expectReasons(body, [], "A specialized map met in a body");
		if (body.metrics.frontendPassFunctions.length != 1)
			throw 'A specialized map met in a body must be typed once: typed ${body.metrics.frontendPassFunctions}';
		expectSameProgram(body, compile("import haxeon.collections.HashMap; " + bodySource), "A specialized map met in a body");

		var withoutStdlib = new Compiler();
		withoutStdlib.update("Main.hx", bodySource);
		var message = try {
			withoutStdlib.compile("Main", null, false);
			"";
		} catch (error:Dynamic) {
			Std.string(error);
		}
		if (message.indexOf('Representation module "haxeon.collections.HashMap" must be seeded') < 0)
			throw 'Without a stdlib root a specialized map must stop the compiler and name the module: $message';
		Sys.println("PASS: only modules that functions call restart the frontend, as a continuation; the map owner needs none");
	}

	static function compile(source:String):compiler.Compiler.CompileResult {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
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
			for (object in result.ir.objects)
				object.name + ":" + [for (field in object.fields) field.name].join(",")
		];
		objects.sort(Reflect.compare);
		return names.join("\n") + "\n#\n" + objects.join("\n");
	}
}
