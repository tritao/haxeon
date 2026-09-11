import compiler.Frontend;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.ir.IrProgramAssembler;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.types.Typer;

class IrProgramAssemblerMain {
	static function main():Void {
		var simple = Frontend.compile("function main():Int return 42;");
		expect(hasNative(simple, "__exit"), "every executable program should include the exit native");
		expect(!hasNative(simple, "__array_alloc_i32"), "unused runtime families should not be assembled");

		var arrays = Frontend.compile("function main():Int { var values = new Array<Int>(1); values[0] = 42; return values[0]; }");
		expect(hasNative(arrays, "__array_alloc_i32"), "array operations should select the array runtime family");
		Frontend.compile('typedef Entry = {name:String, index:Int}; function entries(values:Map<String, Int>):Array<Entry> { var result = [for (name => index in values) {name: name, index: index}]; return result; } function main():Int return 0;');
		var cNative = Frontend.compile('@:cNative("fixture", "fixture_add", "5,5>5") extern function add(left:Int, right:Int):Int; function main():Int return add(19, 23);');
		expect(cNative.cNatives.length == 1 && cNative.cNatives[0].name == "add" && cNative.cNatives[0].signature == "5,5>5",
			"ordinary C declarations should retain their ABI descriptors");
		expect(!hasNative(cNative, "add") && hasCNativeCall(cNative, "add"), "ordinary C calls must remain distinct from HashLink-native calls");
		var cNativeRoundTrip = CanonicalIrCodec.decode(CanonicalIrCodec.encode(cNative));
		expect(cNativeRoundTrip.cNatives.length == 1 && hasCNativeCall(cNativeRoundTrip, "add"),
			"canonical IR must preserve ordinary C native declarations and calls");

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

	static function hasCNativeCall(program:compiler.ir.Ir.IrProgram, name:String):Bool {
		for (fn in program.functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction.value {
						case CNativeCall(_, functionName, _) if (functionName == name):
							return true;
						case _:
					}
		return false;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
