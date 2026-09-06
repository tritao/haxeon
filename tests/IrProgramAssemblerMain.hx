import compiler.Frontend;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.IrProgramAssembler;
import compiler.types.Typer;

class IrProgramAssemblerMain {
	static function main():Void {
		var simple = Frontend.compile("function main():Int return 42;");
		expect(hasNative(simple, "__exit"), "every executable program should include the exit native");
		expect(!hasNative(simple, "__array_alloc_i32"), "unused runtime families should not be assembled");

		var arrays = Frontend.compile("function main():Int { var values = new Array<Int>(1); values[0] = 42; return values[0]; }");
		expect(hasNative(arrays, "__array_alloc_i32"), "array operations should select the array runtime family");

		var source = new SourceFile("Box.hx", "class Box { public var value:Int; } function main():Int return 0;"),
			typed = Typer.type(new Parser(new Lexer(source).tokenize()).parseProgram()),
			objects = IrProgramAssembler.objectsFrom(typed);
		expect(objects.length == 1 && objects[0].name == "Box" && objects[0].fields.length == 1, "typed object metadata should become IR metadata");

		Sys.println("PASS: IR program assembly and runtime selection");
	}

	static function hasNative(program:compiler.ir.Ir.IrProgram, name:String):Bool {
		for (native in program.natives)
			if (native.name == name)
				return true;
		return false;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
