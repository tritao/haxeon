import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * The modules typing can make a body call although its source names none of them are in the graph before anything is typed
 * (`RuntimeType.programModules`, `RuntimeType.companionModules`), so the frontend runs once and the program is the one a compile
 * that imports them makes:
 * - arithmetic on a Dynamic calls `haxeon.DynamicOps`, a field of a Dynamic `Reflect`;
 * - `Bytes.toHex` calls `std.bytes.BytesHex`, which comes with `std.bytes.Bytes`;
 * - a specialized map, met in a field type or only inside a body, needs the map owner's module, which also changes how the
 *   map is represented; without it (no stdlib root) the compiler stops and names the module.
 */
class TypedRuntimeModulesMain {
	static final value =
		"struct Value { public var number:Int; public function new(number:Int) this.number = number; } ";

	static function main():Void {
		var literal = "function keep(value:Dynamic):Void {} function main():Int { keep({count: 42}); return 42; }";
		if (GeneratedProgramRunner.exitCode(compile(literal)) != 42)
			throw "A Dynamic object literal changed behavior";

		var arithmetic =
			"function read(value:Dynamic):Int return value < 0 ? 0 : 42; function main():Int return read(1);";
		var compiled = compile(arithmetic);
		if (compiled.metrics.frontendStages.indexOf("graph=") != 0
			|| compiled.metrics.frontendStages.indexOf("parse-within=") < 0)
			throw 'The frontend must report its stages and its parsing: ${compiled.metrics.frontendStages}';
		expectSameProgram(compiled, compile("import haxeon.DynamicOps; " + arithmetic), "Dynamic arithmetic");

		var field = "class Box { public var count:Int = 42; public function new() {} } "
			+ "function read(value:Dynamic):Int return value.count; function main():Int return read(new Box());";
		expectSameProgram(compile(field), compile("import Reflect; " + field), "A field of a Dynamic");

		var hex = "function main():Int return haxe.io.Bytes.ofString(\"*\").toHex() == \"2a\" ? 42 : 1;";
		expectSameProgram(compile(hex), compile("import std.bytes.BytesHex; " + hex), "Bytes.toHex");

		var fieldSource = value
			+ "class Holder { public var entries:Map<Int, Value>; public function new() {} } "
			+ "function main():Int { var holder = new Holder(); return holder == null ? 1 : 42; }";
		expectSameProgram(compile(fieldSource), compile("import haxeon.collections.HashMap; " + fieldSource),
			"A specialized map field");

		var bodySource = value
			+ "function main():Int { var entries = new Map<Int, Value>(); entries.set(1, new Value(42)); var found = entries.get(1); return found == null ? 1 : found.number; }";
		expectSameProgram(compile(bodySource), compile("import haxeon.collections.HashMap; " + bodySource),
			"A specialized map met in a body");

		var withoutStdlib = new Compiler();
		withoutStdlib.update("Main.hx", bodySource);
		var message = try {
			withoutStdlib.compile("Main", null, false);
			"";
		} catch (error:Dynamic) {
			Std.string(error);
		}
		if (message.indexOf('Module "haxeon.collections.HashMap"') < 0 || message.indexOf("is not in the program") < 0)
			throw 'Without a stdlib root a specialized map must stop the compiler and name the module: $message';
		Sys.println("PASS: every module typing calls is in the graph before typing; the frontend runs once");
	}

	static function compile(source:String):compiler.Compiler.CompileResult {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source);
		return compiler.compile("Main", null, false);
	}

	/** The program does not depend on how the module got there: the same functions and objects as with the module imported. */
	static function expectSameProgram(seeded:compiler.Compiler.CompileResult, imported:compiler.Compiler.CompileResult,
			label:String):Void {
		var left = shape(seeded), right = shape(imported);
		if (left != right)
			throw '$label differs from a compile that imports the module:\n$left\n--\n$right';
		if (GeneratedProgramRunner.exitCode(seeded) != 42)
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
