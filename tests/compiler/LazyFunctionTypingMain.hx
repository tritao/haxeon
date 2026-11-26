using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/**
 * An unannotated function's result and arguments are what its body gives them, typed the first time anything needs them, in the
 * function's own unit (docs/design/LAZY_DECLARATION_TYPING.md, slice 4). The errors Haxeon gives where Haxe would let a caller,
 * in another unit, fix a type, or would type a cycle as Dynamic, are checked with their message and position in both typing
 * orders; so is the output of forced bodies, which must not depend on the order bodies are typed in.
 */
class LazyFunctionTypingMain {
	static function main():Void {
		rejects("a lone null return", [
			"class Main {",
			"	static function f() return null;",
			"	static function main() f();",
			"}"
		],
			"2:9",
			'Cannot infer the return type of function "Main.f": nothing in its body fixes the type of the null it returns; annotate it');
		// The entry point's own result comes from its body: when the body fails, its error is the one reported.
		rejects("an unannotated entry point whose body fails", [
			"class Main {",
			"	static function main() { var x:Int = 'text'; }",
			"}"
		], "2:39", 'Type mismatch for local "x": expected Int, got String');
		rejects("an argument only a caller fixes", [
			"class Main {",
			"	static function g(x) {}",
			"	static function main() g(1);",
			"}"
		], "2:20",
			'Cannot infer the type of argument "x" of function "Main.g": nothing in its body fixes it; annotate it');
		rejects("a cycle of two functions", [
			"class Main {",
			"	static function g() return h();",
			"	static function h() return g();",
			"	static function main() g();",
			"}"
		], "2:9",
			'Function "Main.g" needs a type annotation: its type depends on "Main.h", which depends on it; annotate one of them');
		// Haxe types both as Int (`d` reads `c`'s monomorph and `c` fixes it); Haxeon asks for one annotation.
		rejects("a cycle one member would fix", [
			"class Main {",
			"	static function c() return d() + 1;",
			"	static function d() return c();",
			"	static function main() trace(c());",
			"}"
		], "2:9",
			'Function "Main.c" needs a type annotation: its type depends on "Main.d", which depends on it; annotate one of them');
		rejects("a cycle through a field", [
			"class Main {",
			"	static function f() return x + 1;",
			"	static var x = f();",
			"	static function main() trace(x);",
			"}"
		], "2:9",
			'Function "Main.f" needs a type annotation: its type depends on "Main.x", which depends on it; annotate one of them');
		// A failed body is reported once, by its own unit, and its unannotated result is Dynamic to the bodies that read it.
		rejects("a failed function read by two bodies", [
			"class Main {",
			"	static function broken() return missing;",
			"	static function a() return broken();",
			"	static function b() return broken();",
			"	static function main() { a(); b(); }",
			"}"
		], "2:34", 'Unknown variable "missing"');
		rejects("a value struct's unannotated field", [
			"struct Point {",
			"	var x = 1;",
			"	public function new() {}",
			"}",
			"class Main {",
			"	static function main() new Point();",
			"}"
		], "2:2", 'Value field "Point.x" needs a type annotation: its type is part of the layout');
		// Forcing nests as deep as the chain of functions each calling the next one declared after it.
		var chain = ["class Main {"];
		for (index in 0...199)
			chain.push('	static function f$index() return f${index + 1}() + 1;');
		chain.push("	static function f199() return 1;");
		chain.push("	static function main():Int return f0() - 158;");
		chain.push("}");
		runs("a forced chain of 200 functions", chain, 42);
		runs("functions typed from their bodies", [
			"import haxe.ds.Option;",
			"enum Step { Move(n:Int); Stop; }",
			"class Point {",
			"	public var x:Int;",
			"	public var y:Null<Int>;",
			"	public function new(x, ?y) {",
			"		this.x = x;",
			"		this.y = y;",
			"	}",
			"	public function sum() return x + (y == null ? 0 : y);",
			"}",
			"class Main {",
			"	static var first = make();",
			"	static var doubled = twice(3);",
			"	static function make() return Some(Move(2));",
			"	static function f() return 31;",
			"	static function g() return f() + 1;",
			"	static function twice(x) return x * 2;",
			"	static function fact(n:Int) return if (n == 0) 1 else n * fact(n - 1);",
			"	static function isEven(n:Int):Bool return n == 0 ? true : isOdd(n - 1);",
			"	static function isOdd(n:Int) return n == 0 ? false : isEven(n - 1);",
			"	static function maybe(flag:Bool) {",
			"		if (flag)",
			"			return null;",
			"		return 3;",
			"	}",
			"	static function main():Int {",
			"		var step = switch first { case Some(Move(n)): n; case _: 0; };",
			"		var nothing:Null<Int> = maybe(true);",
			"		var three:Int = maybe(false);",
			"		var even = isEven(4) ? 1 : 0;",
			"		return g() + step + doubled + three - fact(3) + new Point(1, 2).sum() + new Point(1).sum() + even",
			"			- (nothing == null ? 0 : 1);",
			"	}",
			"}"
		], 42);
		Sys.println("PASS: unannotated functions are typed from their bodies on demand, with Haxeon's errors where a caller would fix them");
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
