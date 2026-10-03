import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;

class EnumVisibilityMain {
	static function main():Void {
		var spanFile = new SourceFile("Span.hx", "reference()");
		var bareReference = new SourceSpan(spanFile, 0, 9, true);
		if (bareReference.merge(new SourceSpan(spanFile, 9, 11)).isBareReference)
			throw "merged non-reference spans inherited a bare-reference marker";

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

		var switchedEnum = new Compiler();
		switchedEnum.update("foreign/E.hx", "package foreign; enum E { Preview; Other; }");
		switchedEnum.update("Main.hx",
			'import foreign.E; class Main { static inline var Preview = "preview"; static function main():Int { var value:E = E.Preview; return switch (value) { case Preview: 42; case Other: 0; }; } }');
		switchedEnum.analyze("Main");
		Sys.println("PASS: switched enum constructors win over same-named class fields");

		var moduleImport = new Compiler();
		moduleImport.update("foreign/Shape.hx",
			"package foreign; enum Primitive { Box(size:Int); Sphere(radius:Int); } class Shape { public function new() {} }");
		moduleImport.update("Main.hx",
			'import foreign.Shape; class Main { static function size(value:Primitive):Int return switch value { case Box(size): size; case Sphere(radius): radius; }; static function main():Int { var made = Box(40); return size(made) + size(Sphere(2)); } }');
		moduleImport.analyze("Main");
		Sys.println("PASS: importing a module exposes the constructors of enums declared in it");

		var typeTest = new Compiler();
		typeTest.update("foreign/Value.hx", "package foreign; enum Value { Bool(value:Bool); Int(value:Int); String(value:String); }");
		typeTest.update("Main.hx",
			'import foreign.Value; class Main { static function main():Int { var value:Dynamic = 1; return Std.isOfType(value, Int) && !Std.isOfType(value, Bool) && !Std.isOfType(value, String) ? 42 : 0; } }');
		typeTest.analyze("Main");
		Sys.println("PASS: an imported enum constructor does not capture the type named in Std.isOfType");

		var subTypeImport = new Compiler();
		subTypeImport.update("foreign/Shape.hx",
			"package foreign; enum Primitive { Box(size:Int); } enum Other { Loose; } class Shape { public function new() {} }");
		subTypeImport.update("Main.hx",
			'import foreign.Shape.Primitive; class Main { static function include():foreign.Shape.Other return foreign.Shape.Other.Loose; static function main():Int { var made = Box(42); var loose = Loose; return 0; } }');
		try {
			subTypeImport.analyze("Main");
			throw "a sub-type import exposed another enum's constructors";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1005")
				throw error;
		}
		Sys.println("PASS: importing one module sub-type keeps the module's other enums hidden");

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
