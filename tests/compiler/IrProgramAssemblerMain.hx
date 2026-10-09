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

		var flatRecords = Frontend.compile('struct Leaf { public var tag:UInt8; public var delta:Int16; public var count:Int32; } '
			+ 'struct Root { public var prefix:Int; public var child:Leaf; } function main():Int return 0;'),
			leafObject = findObject(flatRecords.objects, "Leaf"),
			deltaField = findObjectField(leafObject, "delta"),
			rootObject = findObject(flatRecords.objects, "Root"),
			childField = findObjectField(rootObject, "child");
		expect(leafObject.nativeLayout != null && leafObject.nativeLayout.size == 8 && leafObject.nativeLayout.alignment == 4,
			"IR objects must retain selected native record size and alignment");
		expect(deltaField.nativeLayout != null && deltaField.nativeLayout.offset == 2 && deltaField.nativeLayout.size == 2 && deltaField.nativeLayout.signed,
			"IR fields must retain signed narrow field placement for HashLink lowering");
		expect(childField.nativeLayout != null && childField.nativeLayout.offset == 4 && childField.nativeLayout.inlineRecord,
			"nested Flat fields must retain inline record placement");
		var flatRecordsRoundTrip = CanonicalIrCodec.decode(CanonicalIrCodec.encode(flatRecords)),
			roundTripLeaf = findObject(flatRecordsRoundTrip.objects, "Leaf"),
			roundTripDelta = findObjectField(roundTripLeaf, "delta");
		expect(roundTripLeaf.nativeLayout != null
			&& roundTripLeaf.nativeLayout.size == 8
			&& roundTripDelta.nativeLayout != null
			&& roundTripDelta.nativeLayout.offset == 2
			&& roundTripDelta.nativeLayout.signed,
			"canonical IR must round-trip record and narrow-field layout facts");

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

	static function findObject(objects:Array<compiler.ir.Ir.IrObject>, name:String):compiler.ir.Ir.IrObject {
		for (object in objects)
			if (object.name == name)
				return object;
		throw 'Missing IR object "$name"';
	}

	static function findObjectField(object:compiler.ir.Ir.IrObject, name:String):compiler.ir.Ir.IrObjectField {
		for (field in object.fields)
			if (field.name == name)
				return field;
		throw 'Missing IR field "${object.name}.$name"';
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
