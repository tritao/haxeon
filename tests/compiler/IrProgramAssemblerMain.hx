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
		var storageSource = "class Storage { public final length:Int; public function new(length:Int) this.length = length; } "
			+ "@:forward(length) abstract Buffer(Storage) { public function new(length:Int) this = new Storage(length); } ";
		Frontend.compile(storageSource + "function main():Int { var buffer = new Buffer(42); return buffer.length; }");
		for (body in [
			"var buffer = new Buffer(42); buffer.length = 1; return 0;",
			"var storage:Storage = new Buffer(42); return 0;"
		]) {
			var rejected = false;
			try
				Frontend.compile(storageSource + "function main():Int { " + body + " }")
			catch (_:Dynamic)
				rejected = true;
			expect(rejected, "read-only abstract forwarding grants neither writes nor implicit storage conversion");
		}

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

		var managed = Frontend.compile('struct ManagedWidth { public var text:String; public var byte:UInt8; public var short:Int16; } '
			+ 'class ManagedWidthHolder { public var optional:Null<ManagedWidth>; } function main():Int return 0;'),
			managedObject = findObject(managed.objects, "ManagedWidth"),
			byteField = findObjectField(managedObject, "byte"), shortField = findObjectField(managedObject, "short");
		expect(managedObject.nativeLayout == null && byteField.scalarStorage != null && byteField.scalarStorage.size == 1
			&& !byteField.scalarStorage.signed && shortField.scalarStorage != null && shortField.scalarStorage.size == 2
			&& shortField.scalarStorage.signed, "managed values must retain scalar width and signedness without a C layout");
		var wcharSource = new SourceFile("WChar.hx", 'struct FlatWChar { public var value:CWChar; } '
			+ 'struct ManagedWChar { public var text:String; public var value:CWChar; }');
		var wcharProgram = new Parser(new Lexer(wcharSource).tokenize()).parseProgram();
		var windowsFields = IrProgramAssembler.objectsFrom(Typer.typeLibrary(wcharProgram, "x86_64-pc-windows-msvc"));
		var windowsFlat = findObjectField(findObject(windowsFields, "FlatWChar"), "value");
		var windowsManaged = findObjectField(findObject(windowsFields, "ManagedWChar"), "value");
		expect(windowsFlat.nativeLayout != null && windowsFlat.nativeLayout.size == 2 && !windowsFlat.nativeLayout.signed
			&& windowsManaged.scalarStorage != null && windowsManaged.scalarStorage.size == 2 && !windowsManaged.scalarStorage.signed,
			"Windows wchar fields must use unsigned 16-bit storage in flat and managed values");
		var managedRoundTrip = CanonicalIrCodec.decode(CanonicalIrCodec.encode(managed)),
			restoredByte = findObjectField(findObject(managedRoundTrip.objects, "ManagedWidth"), "byte");
		expect(restoredByte.scalarStorage != null && restoredByte.scalarStorage.size == 1 && !restoredByte.scalarStorage.signed,
			"canonical IR must preserve managed scalar storage metadata");
		var optionalSlot = compiler.ir.IrInlineValueLayout.slotName("optional", {
			path: ["byte"], type: compiler.ir.Ir.IrType.I32, isPresence: false, nativeLayout: null
		});
		var optionalByte = findObjectField(findObject(managedRoundTrip.objects, "ManagedWidthHolder"), optionalSlot);
		expect(optionalByte.scalarStorage != null && optionalByte.scalarStorage.size == 1 && !optionalByte.scalarStorage.signed,
			"flattened optional fields must retain the payload's scalar storage");
		var signedManaged = Frontend.compile('struct ManagedWidth { public var text:String; public var byte:Int8; public var short:Int16; } '
			+ 'class ManagedWidthHolder { public var optional:Null<ManagedWidth>; } function main():Int return 0;');
		expect(compiler.abi.RuntimeAbi.describe(managed).objects.get("ManagedWidth")
			!= compiler.abi.RuntimeAbi.describe(signedManaged).objects.get("ManagedWidth"),
			"changing scalar signedness must change the runtime ABI signature");
		managedRoundTrip.objects = [for (object in managedRoundTrip.objects) if (object.name != "ManagedWidth") object else {
			name: object.name, isValue: object.isValue, nativeLayout: object.nativeLayout, base: object.base,
			interfaces: object.interfaces, methods: object.methods,
			fields: [for (field in object.fields) if (field.name != "byte") field else {
				name: field.name, type: field.type, nativeLayout: field.nativeLayout, scalarStorage: {size: 3, signed: false}
			}]
		}];
		var rejectedStorage = false;
		try compiler.ir.IrVerifier.verify(managedRoundTrip) catch (_:Dynamic) rejectedStorage = true;
		expect(rejectedStorage, "IR verification must reject invalid scalar storage widths");
		var interpretedNarrow = Frontend.compile('struct InterpretedWidth { public var text:String; public var value:UInt8; '
			+ 'public function new() { text = "x"; value = 0; } } '
			+ 'function main():Int { var item = new InterpretedWidth(); item.value = cast 257; return cast item.value; }');
		expect(new compiler.ir.IrInterpreter(interpretedNarrow).run("main") == 1,
			"IR interpretation must apply the same narrow field stores as the backends");
		var nullableWidth = Frontend.compile('struct NullableWidth { public var text:String; public var value:Null<UInt8>; '
			+ 'public function new() { text = "x"; value = null; } } '
			+ 'function main():Int { var item = new NullableWidth(); item.value = cast 257; return cast item.value; }');
		var nullableField = findObjectField(findObject(nullableWidth.objects, "NullableWidth"), "value");
		expect(nullableField.nullableScalarStorage != null && nullableField.nullableScalarStorage.size == 1
			&& !nullableField.nullableScalarStorage.signed, "nullable fields must preserve payload width and signedness");
		var nullableRoundTrip = CanonicalIrCodec.decode(CanonicalIrCodec.encode(nullableWidth));
		var restoredNullable = findObjectField(findObject(nullableRoundTrip.objects, "NullableWidth"), "value");
		expect(restoredNullable.nullableScalarStorage != null && restoredNullable.nullableScalarStorage.size == 1,
			"canonical IR must preserve nullable scalar payload metadata");
		expect(new compiler.ir.IrInterpreter(nullableWidth).run("main") == 1,
			"IR interpretation must normalize nullable narrow payloads");

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
