using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/**
 * An object literal's structure stays open while its unit is typed, gains the optional fields of the structures it meets, and is
 * closed and named when the unit's frame is settled (docs/design/STRUCTURE_VALUES.md, slice 5). A use in another unit that would
 * add a field to it is an error asking for an annotation (decision 3): Haxe accepts it for a field, whose structure it keeps
 * open, and rejects it for a function's result. The messages and positions are checked in both typing orders; a program whose
 * literals gain fields builds to the same bytes in both.
 */
class OpenLiteralStructureMain {
	static function main():Void {
		rejects("a literal held by an unannotated field", [
			"class Main {",
			"	static var config = {name: \"x\"};",
			"	static function main() {",
			"		var c:{name:String, ?debug:Bool} = config;",
			"		trace(c.name);",
			"	}",
			"}"
		], "4:38",
			'{name : String} has no field debug; the structure comes from a literal in "Main.config", which closed its type; annotate the type of field "Main.config"');
		rejects("a literal returned by an unannotated function", [
			"class Lib {",
			"	public static function make() {",
			"		var made = {name: \"x\", size: 1};",
			"		return made;",
			"	}",
			"}",
			"class Main {",
			"	static function main() {",
			"		var c:{name:String, size:Int, ?debug:Bool, ?level:Int} = Lib.make();",
			"		trace(c.name);",
			"	}",
			"}"
		], "9:60",
			'{name : String, size : Int} has no field debug; the structure comes from a literal in "Lib.make", which closed its type; annotate the result of "Lib.make"');
		runs("literals that gain optional fields", [
			"typedef Argument = {name:String, ?optional:Bool, ?defaultValue:String};",
			"class Main {",
			"	static function count(arguments:Array<Argument>):Int {",
			"		var total = 0;",
			"		for (argument in arguments)",
			"			total += argument.optional == true ? 10 : 1;",
			"		return total;",
			"	}",
			"	static function helper() {",
			"		var nested = {inner: {a: 1}};",
			"		var wide:{inner:{a:Int, ?b:Int}} = nested;",
			"		wide.inner.b = 2;",
			"		return nested.inner.b;",
			"	}",
			"	static function main():Int {",
			"		var arguments = [];",
			"		for (name in [\"a\", \"b\"])",
			"			arguments.push({name: name});",
			"		var before = count(arguments);",
			"		arguments[1].optional = true;",
			"		var c = {name: \"c\"};",
			"		var d:{name:String, ?level:Int} = c;",
			"		d.level = 29;",
			"		return count(arguments) + c.level + helper() + (before == 2 ? 0 : 100);",
			"	}",
			"}"
		], 42);
		Sys.println("PASS: object literals gain optional fields while their unit is typed, and a use in another unit asks for an annotation");
	}

	static function compiler(reverse:Bool):Compiler {
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = false;
		c.options = new CompileOptions({reverseTypingOrder: reverse});
		c.addSourceRoot("stdlib");
		return c;
	}

	/** Both typing orders reject `lines` with exactly one error, `message` at `position` (line:column). */
	static function rejects(label:String, lines:Array<String>, position:String, message:String):Void
		for (reverse in [false, true]) {
			var c = compiler(reverse);
			c.update("Main.hx", lines.join("\n"));
			var error = try {
				c.compile("Main");
				null;
			} catch (error:CompileError) error;
			if (error == null)
				throw '$label: compiled';
			var diagnostic = error.diagnostic,
				where = diagnostic.span.file.lineColumnAt(diagnostic.span.start),
				actual = '${where.line}:${where.column}';
			if (error.diagnostics.length != 1 || diagnostic.message != message || actual != position)
				throw '$label${reverse ? " (reverse typing order)" : ""}: expected "$message" at $position, got '
					+ [for (each in error.diagnostics) each.format()].join("; ");
		}

	/** `lines` builds to the same bytes in both typing orders and exits with `expected`. */
	static function runs(label:String, lines:Array<String>, expected:Int):Void {
		var modules = [for (reverse in [false, true]) {
			var c = compiler(reverse);
			c.update("Main.hx", lines.join("\n"));
			c.compile("Main");
		}];
		var forward = modules[0].artifact.hashLink().hashLinkBytes().flatten(),
			backward = modules[1].artifact.hashLink().hashLinkBytes().flatten();
		if (forward.compare(backward) != 0)
			throw '$label: the reverse typing order gives other bytes';
		var exit = GeneratedProgramRunner.exitCode(modules[0]);
		if (exit != expected)
			throw '$label: exited with $exit, expected $expected';
	}
}
