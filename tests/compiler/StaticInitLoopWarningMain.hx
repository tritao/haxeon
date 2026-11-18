import compiler.Compiler;
import compiler.core.Diagnostic;
import compiler.runtime.CompilerIntrinsics;

/**
 * W1002, Haxe's "maybe loop in static generation" warning: a class the static initialization order reaches while it is still
 * being placed, from another class's walk, warns at its declaration. A class reading its own statics does not, and the warning
 * goes when the loop does.
 */
class StaticInitLoopWarningMain {
	static final looping = "class A {\n\tpublic static var a = B.b + 1;\n\tpublic static function f() return 5;\n}\n"
		+ "class B {\n\tpublic static var b = A.f() + B.c;\n\tpublic static var c = 2;\n}\n";
	static final entry = "class Main {\n\tstatic function main() {\n\ttrace(A.a);\n\t}\n}\n";

	static function main():Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.update("Main.hx", looping + entry);
		var warnings = compile(compiler);
		if (warnings.length != 1 || warnings[0].code != "W1002" || !warnings[0].severity.match(Warning)
			|| warnings[0].message != "maybe loop in static generation of A")
			throw 'expected the loop warning for A, got ${describe(warnings)}';
		var at = warnings[0].span.file.lineColumnAt(warnings[0].span.start);
		if (at.line != 1 || at.column != 1)
			throw 'the warning should be at the declaration of A, got ${warnings[0].format()}';

		// The same program compiled again keeps its warning.
		compiler.update("Main.hx", looping + entry + "\n");
		if (compile(compiler).length != 1)
			throw "a rebuild lost the loop warning";

		// B no longer reaches A: no loop, no warning.
		compiler.update("Main.hx", StringTools.replace(looping, "A.f() + ", "") + entry);
		warnings = compile(compiler);
		if (warnings.length != 0)
			throw 'a program without a loop warned: ${describe(warnings)}';
		Sys.println("PASS: a static initialization loop warns at the class, as Haxe does, and the warning leaves with the loop");
	}

	static function compile(compiler:Compiler):Array<Diagnostic>
		return [
			for (warning in compiler.warnings(compiler.compile("Main").moduleNames))
				if (warning.code == "W1002") warning
		];

	static function describe(diagnostics:Array<Diagnostic>):String
		return '[' + [for (diagnostic in diagnostics) diagnostic.format()].join("; ") + ']';
}
