using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;

/**
 * An unannotated field's type is its initializer's, typed the first time anything needs it, in its own unit
 * (docs/design/LAZY_DECLARATION_TYPING.md, slice 3). The errors Haxeon gives where Haxe would let a later use, in another unit,
 * fix the type are checked with their message and position, in both typing orders; so is the output of forced initializers,
 * which must not depend on the order bodies are typed in.
 */
class LazyFieldTypingMain {
	static function main():Void {
		rejects("an empty array", ["class Main {", "	static var e = [];", "	static function main() e.push(1);", "}"],
			"2:9",
			'Cannot infer the type of field "Main.e": nothing in its initializer fixes the element type of this empty array; annotate the field\'s type');
		rejects("an empty map", [
			"class Main {",
			"	static var m = new Map();",
			"	static function main() m.set(1, 2);",
			"}"
		],
			"2:9",
			'Cannot infer the type of field "Main.m": nothing in its initializer fixes the key type of this empty map; annotate the field\'s type');
		rejects("a lone null", ["class Main {", "	static var n = null;", "	static function main() n = 1;", "}"], "2:9",
			'Cannot infer the type of field "Main.n": nothing in its initializer fixes the type of its null value; annotate the field\'s type');
		// The diagnostic is on the first field of the cycle in declaration order, whichever was forced first.
		var cycle = [
			"class Other {",
			"	public static var c = Main.a * 2;",
			"}",
			"class Main {",
			"	static var b = Other.c + 1;",
			"	public static var a = b + 1;",
			"	static function main() trace(a);",
			"}"
		];
		rejects("a cycle of three fields", cycle, "2:16",
			'Field "Other.c" needs a type annotation: its type depends on "Main.a" and "Main.b", which depend on it; annotate one of them');
		rejects("a cycle of two fields", [
			"class Main {",
			"	static var a = b + 1;",
			"	static var b = a + 1;",
			"	static function main() trace(a);",
			"}"
		], "2:9",
			'Field "Main.a" needs a type annotation: its type depends on "Main.b", which depends on it; annotate one of them');
		// Forcing nests as deep as the chain of fields each reading the next one declared after it. They run in declaration
		// order, as in Haxe, so f0 reads f1 before it is set: 0 + 1.
		var chain = ["class Main {"];
		for (index in 0...199)
			chain.push('	static var f$index = f${index + 1} + 1;');
		chain.push("	static var f199 = 1;");
		chain.push("	static function main():Int return f0 + 41;");
		chain.push("}");
		runs("a forced chain of 200 fields", chain, 42);
		runs("fields typed from their initializers", [
			"import haxe.ds.Option;",
			"enum Step { Move(n:Int); Stop; }",
			"class Lib { public static function f():Int return 40; }",
			"class Bag<T> {",
			"	public var items = new Array<T>();",
			"	public var counts = [for (i in 0...3) i];",
			"	public function new() {}",
			"}",
			"class Main {",
			"	static final start = Some(Move(1));",
			"	static var names = [\"a\", \"bc\"];",
			"	static var lengths = names.map(s -> s.length);",
			"	static var twice = (x:Int) -> x * 2;",
			"	static var x = Lib.f() + 1;",
			"	static function main():Int {",
			"		var bag = new Bag<Int>();",
			"		bag.items.push(lengths[1]);",
			"		var first:Int = bag.items[0];",
			"		var step = switch start { case Some(Move(n)): n; case _: 0; };",
			"		var t = twice;",
			"		return first + step + t(1) + x - 4 + bag.counts[2] - 2;",
			"	}",
			"}"
		], 42);
		Sys.println("PASS: unannotated fields are typed from their initializers on demand, with Haxeon's errors where a later use would fix them");
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
		var forward = HlWriter.encode(modules[0].artifact.hashLink().module).flatten(),
			backward = HlWriter.encode(modules[1].artifact.hashLink().module).flatten();
		if (forward.compare(backward) != 0)
			throw '$label: the reverse typing order gives other bytes';
		var exit = GeneratedProgramRunner.exitCode(modules[0]);
		if (exit != expected)
			throw '$label: exited with $exit, expected $expected';
	}
}
