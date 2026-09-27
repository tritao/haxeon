import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class EnumVisibilityMain {
	static function main():Void {
		var samePackage = new Compiler();
		samePackage.addSourceRoot("tests/compiler");
		samePackage.update("samepackage/SamePackageLookupMain.hx", sys.io.File.getContent("tests/compiler/samepackage/SamePackageLookupMain.hx"));
		samePackage.analyze("samepackage.SamePackageLookupMain");
		Sys.println("PASS: same-package constructor loads without an import");
		var compiler = new Compiler();
		compiler.update("foreign/E.hx", "package foreign; enum E { Length; }");
		compiler.update("Main.hx",
			'class Main { static inline var Length = "length"; static function include():foreign.E return foreign.E.Length; static function main():Int { var value = "length"; return switch (value) { case Length: 42; default: 0; }; } }');
		compiler.analyze("Main");
		Sys.println("PASS: class field wins over unrelated enum constructor");

		var imported = new Compiler();
		imported.update("foreign/E.hx", "package foreign; enum E { Length; }");
		imported.update("Main.hx",
			'import foreign.E; class Main { static inline var Length = "length"; static function main():Int { var value = "length"; return switch (value) { case Length: 42; default: 0; }; } }');
		imported.analyze("Main");
		Sys.println("PASS: class field wins over imported enum constructor");

		var duplicates = new Compiler();
		duplicates.update("first/E.hx", "package first; enum E { Length; }");
		duplicates.update("second/E.hx", "package second; enum E { Length; }");
		duplicates.update("Main.hx",
			'class Main { static inline var Length = "length"; static function includeFirst():first.E return first.E.Length; static function includeSecond():second.E return second.E.Length; static function main():Int { var value = "length"; return switch (value) { case Length: 42; default: 0; }; } }');
		duplicates.analyze("Main");
		Sys.println("PASS: duplicate enum constructors do not shadow class field");

		var explicit = new Compiler();
		explicit.update("foreign/E.hx", "package foreign; enum E { Length; }");
		explicit.update("other/E.hx", "package other; enum E { Length; }");
		explicit.update("Main.hx",
			'import foreign.E; class Main { static function include():other.E return other.E.Length; static function main():Int { var value:E = Length; return value == E.Length ? 42 : 0; } }');
		explicit.analyze("Main");
		Sys.println("PASS: explicit enum import remains visible with duplicate constructors elsewhere");

		var expected = new Compiler();
		expected.update("foreign/E.hx", "package foreign; enum E { Length; }");
		expected.update("other/E.hx", "package other; enum E { Length; }");
		expected.update("Main.hx",
			'import foreign.E; class Main { static function include():other.E return other.E.Length; static function main():Int { var value:other.E = Length; return switch (value) { case Length: 42; }; } }');
		expected.analyze("Main");
		Sys.println("PASS: expected enum wins over a different imported constructor");

		var hidden = new Compiler();
		hidden.update("foreign/E.hx", "package foreign; enum E { Length; }");
		hidden.update("Main.hx",
			'class Main { static function include():foreign.E return foreign.E.Length; static function main():Int { var value = Length; return 0; } }');
		try {
			hidden.analyze("Main");
			throw "an enum constructor from an unrelated file was visible";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1005")
				throw error;
		}
		Sys.println("PASS: unimported enum constructor stays hidden");
	}
}
