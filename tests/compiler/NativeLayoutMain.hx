import compiler.Diagnostic.CompileError;
import compiler.Compiler;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue.*;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue;
import compiler.types.Type.NominalKind;
import compiler.types.Type.CompilerType;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;

class NativeLayoutMain {
	static function main():Void {
		var float32BitCases:Array<{value:Float, bits:Int}> = [
			{value: 0.1, bits: 0x3DCCCCCD},
			{value: -0.1, bits: 0xBDCCCCCD},
			{value: 1.401298464324817e-45, bits: 1},
			{value: 1.0000000596046448, bits: 0x3F800000},
			{value: 1.1754943508222875e-38, bits: 0x00800000},
			{value: 3.4028234663852886e38, bits: 0x7F7FFFFF}
		];
		for (test in float32BitCases)
			expect(compiler.types.NativeTypeDescriptor.float32DefaultBits(test.value) == test.bits,
				'Float32 descriptor rounding must produce IEEE-754 bits for ${test.value}');
		expect(compiler.types.NativeTypeDescriptor.float32DefaultBits(3.4028235677973366e38) == null,
			"Float32 descriptor rounding must reject the overflow midpoint");
		var source = '@:value @:repr("C") class Pair { public var tag:UInt8; public var value:Int64; public var ratio:Float32; } '
			+ '@:value @:repr("C") class Outer { public var first:Pair; public var second:Pair; } '
			+ '@:value @:repr("C") class LongValue { public var value:CLong; } '
			+ 'function pairSize():Int return sizeof<Pair>(); '
			+ 'function pairAlignment():Int return alignof<Pair>(); '
			+ 'function valueOffset():Int return offsetof<Pair>("value"); '
			+ 'function pairInfoSize():Null<Int> return typeInfo<Pair>().size; '
			+ 'function longSize():Int return sizeof<CLong>();',
			program = new Parser(new Lexer(new SourceFile("native-layout.hx", source)).tokenize()).parseProgram(),
			typed = Typer.typeLibrary(program),
			pair = requireClass(typed.classes, "Pair"),
			outer = requireClass(typed.classes, "Outer"),
			longValue = requireClass(typed.classes, "LongValue");
		if (!pair.isNativeValue || pair.isValue || pair.nativeLayouts.length < 2)
			throw "C-represented values must be distinct typed declarations with per-ABI layouts";
		switch compiler.types.DeclarationIndex.validated(program).resolve(compiler.syntax.Ast.AstType.NamedType("Pair")) {
			case CompilerType.TInstance(NominalKind.NativeValue, "Pair", []):
			case _:
				throw "native value declarations resolved as managed classes";
		}
		var pair32 = requireLayout(pair.nativeLayouts, "portable-abi32"),
			pair64 = requireLayout(pair.nativeLayouts, "portable-abi64"),
			outer32 = requireLayout(outer.nativeLayouts, "portable-abi32"),
			outer64 = requireLayout(outer.nativeLayouts, "portable-abi64");
		var pairDescriptor = requireDescriptor(typed.nativeTypeDescriptors, "Pair"),
			outerDescriptor = requireDescriptor(typed.nativeTypeDescriptors, "Outer");
		expect(pairDescriptor.size == pair64.size
			&& pairDescriptor.alignment == pair64.alignment
			&& descriptorField(pairDescriptor.fields, "value").offset == field(pair64.fields, "value").offset
			&& descriptorField(pairDescriptor.fields, "ratio").offset == field(pair64.fields, "ratio").offset,
			"descriptor source data must agree with sizeof, alignof, and offsetof layout facts");
		expect(outerDescriptor.fields.length == 2 && descriptorField(outerDescriptor.fields, "first").fields.length == 3,
			"descriptor artifact must recursively describe nested records whether queried directly or not");
		var descriptorBytes = compiler.types.NativeTypeDescriptorCodec.encode(typed.nativeTypeDescriptors),
			decodedDescriptors = compiler.types.NativeTypeDescriptorCodec.decode(descriptorBytes);
		expect(descriptorBytes.get(0) == 72
			&& descriptorBytes.get(1) == 84
			&& descriptorBytes.get(2) == 68
			&& descriptorBytes.get(3) == compiler.types.NativeTypeDescriptorCodec.FORMAT_VERSION,
			"descriptor binary artifact must carry its magic and format version");
		expect(compiler.types.NativeTypeDescriptorCodec.toJson(decodedDescriptors) == compiler.types.NativeTypeDescriptorCodec.toJson(typed.nativeTypeDescriptors),
			"descriptor binary round-trip must preserve the stable JSON representation");
		var unsupportedDescriptorVersion = descriptorBytes.sub(0, descriptorBytes.length);
		unsupportedDescriptorVersion.set(3, compiler.types.NativeTypeDescriptorCodec.FORMAT_VERSION + 1);
		expectDescriptorCodecError(() -> compiler.types.NativeTypeDescriptorCodec.decode(unsupportedDescriptorVersion), "Unsupported");
		var legacyDescriptorVersion = descriptorBytes.sub(0, descriptorBytes.length);
		legacyDescriptorVersion.set(3, 1);
		expectDescriptorCodecError(() -> compiler.types.NativeTypeDescriptorCodec.decode(legacyDescriptorVersion), "Unsupported");
		expectDescriptorCodecError(() -> compiler.types.NativeTypeDescriptorCodec.decode(descriptorBytes.sub(0, descriptorBytes.length - 1)), "Truncated");
		// portable-abi32 is the Wasm32 C ABI, which aligns 64-bit integers to eight bytes.
		expect(pair32.size == 24
			&& pair32.alignment == 8
			&& field(pair32.fields, "value").offset == 8
			&& field(pair32.fields, "ratio").offset == 16,
			"32-bit portable C record layout must align 64-bit integers to eight bytes, as Wasm32 does");
		expect(pair64.size == 24
			&& pair64.alignment == 8
			&& field(pair64.fields, "value").offset == 8
			&& field(pair64.fields, "ratio").offset == 16,
			"64-bit C record layout must preserve padding and field offsets");
		expect(outer32.size == 48
			&& field(outer32.fields, "second").offset == 24
			&& outer64.size == 48
			&& field(outer64.fields, "second").offset == 24,
			"nested native records must contribute their target-specific layout");
		expect(requireLayout(longValue.nativeLayouts, "portable-abi32").size == 4
			&& requireLayout(longValue.nativeLayouts, "portable-abi64").size == 8,
			"C long fields must follow the target ABI integer width");
		var typed32 = Typer.typeLibrary(program, "portable-abi32"),
			typedI386 = Typer.typeLibrary(program, "i686-linux-gnu"),
			typed64 = Typer.typeLibrary(program, "portable-abi64"),
			windows64 = Typer.typeLibrary(program, "x86_64-pc-windows-msvc");
		expect(constantReturn(typed32.functions, "pairSize") == 24
			&& constantReturn(typed32.functions, "pairAlignment") == 8
			&& constantReturn(typed32.functions, "valueOffset") == 8
			&& constantReturn(typed32.functions, "longSize") == 4,
			"native layout intrinsics must fold to the selected 32-bit ABI facts");
		expect(constantReturn(typedI386.functions, "pairSize") == 16
			&& constantReturn(typedI386.functions, "pairAlignment") == 4
			&& constantReturn(typedI386.functions, "valueOffset") == 4,
			"System V i386 C records must align 64-bit integers to four bytes");
		expect(constantReturn(typed64.functions, "pairSize") == 24
			&& constantReturn(typed64.functions, "pairAlignment") == 8
			&& constantReturn(typed64.functions, "valueOffset") == 8
			&& constantReturn(typed64.functions, "longSize") == 8,
			"native layout intrinsics must fold to the selected 64-bit ABI facts");
		expect(constantReturn(windows64.functions, "pairSize") == 24
			&& constantReturn(windows64.functions, "valueOffset") == 8
			&& constantReturn(windows64.functions, "longSize") == 4,
			"C long layout queries must follow the selected Windows LLP64 ABI");
		var targetCompiler = new Compiler();
		targetCompiler.configure("native-layout-wasm32", "native-layout-wasm32", ["target=wasm32"]);
		targetCompiler.update("NativeLayoutMain.hx",
			'@:value @:repr("C") class Pair { public var tag:UInt8; public var value:Int64; public var ratio:Float32; } ' +
			'function main():Int return sizeof<Pair>();');
		var compiled = targetCompiler.compile("NativeLayoutMain"),
			compiledPair = requireClass(targetCompiler.lastTypedProgram.classes, "Pair");
		expect(requireLayout(compiledPair.nativeLayouts, "portable-abi32").size == 24 && compiled.module.ints.indexOf(24) >= 0,
			"CLI target selection must reach typing and lower layout intrinsics as constants");
		var hxiTargetCompiler = new Compiler();
		hxiTargetCompiler.addFfiInterface("native-layout-target.hxi", 'interface target @target("x86_64-pc-windows-msvc") { }');
		expect(hxiTargetCompiler.nativeLayoutTarget() == "x86_64-pc-windows-msvc", "the registered HXI target must select source-declared C record layouts");
		hxiTargetCompiler.update("Target.hx",
			'@:value @:repr("C") class LongRecord { public var value:CLong; } ' + 'function main():Int return sizeof<LongRecord>();');
		var hxiCompiled = hxiTargetCompiler.compile("Target"),
			hxiLongRecord = requireClass(hxiTargetCompiler.lastTypedProgram.classes, "LongRecord");
		expect(requireLayout(hxiLongRecord.nativeLayouts, "x86_64-pc-windows-msvc").size == 4 && hxiCompiled.module.ints.indexOf(4) >= 0,
			"the registered HXI target must reach record layout and query constant folding");
		var cachedLayoutCompiler = new Compiler();
		cachedLayoutCompiler.configure("native-layout-cached", "native-layout-cached", ["native-abi-target=portable-abi64"]);
		cachedLayoutCompiler.update("Transform.hx", '@:value @:repr("C") class Transform { public var x:Float; public var y:Float; public var z:Float; }');
		var cachedMain = 'class Main { static function main():Int return sizeof<Transform>() == 24 ? 42 : 1; }';
		cachedLayoutCompiler.update("Main.hx", cachedMain);
		cachedLayoutCompiler.compile("Main");
		cachedLayoutCompiler.update("Main.hx", StringTools.replace(cachedMain, "sizeof<Transform>() == 24", "alignof<Transform>() == 8"));
		var cachedLayoutCompiled = cachedLayoutCompiler.compile("Main"),
			cachedTransform = requireClass(cachedLayoutCompiler.lastTypedProgram.classes, "Transform");
		expect(requireLayout(cachedTransform.nativeLayouts, "portable-abi64").size == 24
			&& cachedLayoutCompiled.module.ints.indexOf(42) >= 0,
			"retyped class methods must see cached cross-module layouts before folding sizeof/alignof queries");
		var descriptorCompiler = new Compiler();
		descriptorCompiler.configure("type-info-cache", "type-info-cache", ["native-abi-target=portable-abi64"]);
		descriptorCompiler.update("Record.hx", "struct Record { public var x:Int; }");
		descriptorCompiler.update("Main.hx", "class Main { static function main():Int return typeInfo<Record>().hash.length; }");
		var firstDescriptorCompile = descriptorCompiler.compile("Main"),
			firstDescriptorHash = findDescriptorHash(firstDescriptorCompile.module.strings);
		if (firstDescriptorHash == null)
			throw "compiled typeInfo call did not publish its descriptor hash";
		descriptorCompiler.update("Record.hx", "struct Record { public var x:Int; public var y:Int; }");
		var changedDescriptorCompile = descriptorCompiler.compile("Main"),
			changedDescriptorHash = findDescriptorHash(changedDescriptorCompile.module.strings);
		expect(changedDescriptorHash != null && changedDescriptorHash != firstDescriptorHash,
			'changing a struct schema must change the emitted typeInfo hash: before=$firstDescriptorHash after=$changedDescriptorHash retyped=${changedDescriptorCompile.retyped}');
		expect(changedDescriptorCompile.retyped.indexOf("Main.main") >= 0, "changing a struct schema must retype callers of typeInfo");
		var descriptorInvalidated = false;
		for (artifact in changedDescriptorCompile.invalidations)
			if (artifact.artifact == "Main.main")
				for (reason in artifact.reasons)
					if (reason.kind == compiler.semantic.Invalidation.InvalidationKind.StructuralDependency && reason.cause == "Record")
						descriptorInvalidated = true;
		expect(descriptorInvalidated, "changing a struct schema must report the typeInfo layout dependency invalidation");
		var defaultCompiler = new Compiler();
		defaultCompiler.configure("descriptor-defaults", "descriptor-defaults", ["native-abi-target=portable-abi64"]);
		defaultCompiler.update("model/Leaf.hx",
			"package model; struct Leaf { public var zero:Int = 0; public var absent:String; public var nullable:Null<Int> = null; " +
			"public var ratio:Float32 = 0.1; public var unsignedByte:UInt8 = 250; public var signedByte:Int8 = -128; " +
			"public var unsignedWord:UInt16 = 65535; public var signedWord:Int16 = -32768; }");
		defaultCompiler.update("model/Root.hx", "package model; struct Root { public var leaf:Leaf; }");
		defaultCompiler.update("Main.hx", "import model.Root; class Main { static function main():Int return typeInfo<Root>().hash.length; }");
		defaultCompiler.compile("Main");
		var defaultRoot = requireDescriptor(defaultCompiler.lastTypedProgram.nativeTypeDescriptors, "model.Root"),
			defaultLeaf = descriptorField(defaultRoot.fields, "leaf");
		var defaultJson = compiler.types.NativeTypeDescriptorCodec.toJson([defaultRoot]);
		expect(defaultJson.indexOf("0.100000001490116119384765625") >= 0,
			"Float32 descriptor JSON must emit enough decimal digits to preserve the exact binary32 value");
		expect(defaultLeaf.defaultValue == null, "a nested field without a source initializer must be explicitly absent");
		var zeroDefault = descriptorField(defaultLeaf.fields, "zero").defaultValue,
			absentDefault = descriptorField(defaultLeaf.fields, "absent").defaultValue,
			nullDefault = descriptorField(defaultLeaf.fields, "nullable").defaultValue,
			unsignedByteDefault = descriptorField(defaultLeaf.fields, "unsignedByte").defaultValue,
			float32Default = descriptorField(defaultLeaf.fields, "ratio").defaultValue,
			signedByteDefault = descriptorField(defaultLeaf.fields, "signedByte").defaultValue,
			unsignedWordDefault = descriptorField(defaultLeaf.fields, "unsignedWord").defaultValue,
			signedWordDefault = descriptorField(defaultLeaf.fields, "signedWord").defaultValue;
		expect(zeroDefault != null && zeroDefault.type == "Int" && Type.enumEq(zeroDefault.value, IntValue(0)),
			"an explicit integer zero must remain a typed default");
		expect(absentDefault == null, "a field with no initializer must not be confused with a null value");
		expect(nullDefault != null && nullDefault.type == "Null" && Type.enumEq(nullDefault.value, NullValue),
			"an explicit nullable null must survive as a typed default value");
		expect(unsignedByteDefault != null
			&& unsignedByteDefault.type == "Int"
			&& Type.enumEq(unsignedByteDefault.value, IntValue(250))
			&& float32Default != null
			&& float32Default.type == "Float"
			&& Type.enumEq(float32Default.value, NativeTypeAnnotationValue.FloatValue(haxe.io.FPHelper.i32ToFloat(0x3DCCCCCD)))
			&& signedByteDefault != null
			&& Type.enumEq(signedByteDefault.value, IntValue(-128))
			&& unsignedWordDefault != null
			&& Type.enumEq(unsignedWordDefault.value, IntValue(65535))
			&& signedWordDefault != null
			&& Type.enumEq(signedWordDefault.value, IntValue(-32768)),
			"fixed-width 8-bit and 16-bit integer scalar defaults must preserve their signed and unsigned bounds");
		var defaultRoundTrip = compiler.types.NativeTypeDescriptorCodec.decode(compiler.types.NativeTypeDescriptorCodec.encode([defaultRoot])),
			roundTripLeaf = descriptorField(requireDescriptor(defaultRoundTrip, "model.Root").fields, "leaf");
		expect(compiler.types.NativeTypeDescriptorCodec.toJson(defaultRoundTrip) == compiler.types.NativeTypeDescriptorCodec.toJson([defaultRoot])
			&& descriptorField(roundTripLeaf.fields, "zero").defaultValue.type == "Int"
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "zero").defaultValue.value, IntValue(0))
			&& descriptorField(roundTripLeaf.fields, "absent").defaultValue == null
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "nullable").defaultValue.value, NullValue)
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "ratio").defaultValue.value,
				NativeTypeAnnotationValue.FloatValue(haxe.io.FPHelper.i32ToFloat(0x3DCCCCCD)))
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "unsignedByte").defaultValue.value, IntValue(250))
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "signedByte").defaultValue.value, IntValue(-128))
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "unsignedWord").defaultValue.value, IntValue(65535))
			&& Type.enumEq(descriptorField(roundTripLeaf.fields, "signedWord").defaultValue.value, IntValue(-32768)),
			"nested absent, zero, null, narrow integer, and Float32 defaults must survive binary artifact round-trip");
		var narrowDescriptor = requireDescriptor(defaultCompiler.lastTypedProgram.nativeTypeDescriptors, "model.Leaf"),
			malformedNarrowDescriptor:Dynamic = Reflect.copy(narrowDescriptor),
			malformedNarrowFields = narrowDescriptor.fields.copy();
		for (index in 0...malformedNarrowFields.length)
			if (malformedNarrowFields[index].name == "unsignedByte") {
				var malformedField:Dynamic = Reflect.copy(malformedNarrowFields[index]),
					malformedDefault:Dynamic = Reflect.copy(malformedField.defaultValue);
				Reflect.setField(malformedDefault, "value", IntValue(256));
				Reflect.setField(malformedField, "defaultValue", malformedDefault);
				malformedNarrowFields[index] = cast malformedField;
			}
		Reflect.setField(malformedNarrowDescriptor, "fields", malformedNarrowFields);
		Reflect.setField(malformedNarrowDescriptor, "hash",
			compiler.types.NativeTypeDescriptor.contentHash(malformedNarrowDescriptor.type, malformedNarrowDescriptor.name, malformedNarrowDescriptor.type,
				malformedNarrowDescriptor.flat, malformedNarrowDescriptor.portable, malformedNarrowDescriptor.size, malformedNarrowDescriptor.alignment,
				malformedNarrowDescriptor.annotations, malformedNarrowDescriptor.annotationValues, malformedNarrowDescriptor.fields,
				malformedNarrowDescriptor.arguments));
		expectDescriptorCodecError(() -> compiler.types.NativeTypeDescriptorCodec.encode([cast malformedNarrowDescriptor]), "does not match its semantic type");
		var malformedFloat32Descriptor:Dynamic = Reflect.copy(narrowDescriptor),
			malformedFloat32Fields = narrowDescriptor.fields.copy();
		for (index in 0...malformedFloat32Fields.length)
			if (malformedFloat32Fields[index].name == "ratio") {
				var malformedField:Dynamic = Reflect.copy(malformedFloat32Fields[index]),
					malformedDefault:Dynamic = Reflect.copy(malformedField.defaultValue);
				Reflect.setField(malformedDefault, "value", NativeTypeAnnotationValue.FloatValue(cast 0.1));
				Reflect.setField(malformedField, "defaultValue", malformedDefault);
				malformedFloat32Fields[index] = cast malformedField;
			}
		Reflect.setField(malformedFloat32Descriptor, "fields", malformedFloat32Fields);
		Reflect.setField(malformedFloat32Descriptor, "hash",
			compiler.types.NativeTypeDescriptor.contentHash(malformedFloat32Descriptor.type, malformedFloat32Descriptor.name, malformedFloat32Descriptor.type,
				malformedFloat32Descriptor.flat, malformedFloat32Descriptor.portable, malformedFloat32Descriptor.size, malformedFloat32Descriptor.alignment,
				malformedFloat32Descriptor.annotations, malformedFloat32Descriptor.annotationValues, malformedFloat32Descriptor.fields,
				malformedFloat32Descriptor.arguments));
		expectDescriptorCodecError(() -> compiler.types.NativeTypeDescriptorCodec.encode([cast malformedFloat32Descriptor]),
			"does not match its semantic type");
		var originalDefaultHash = defaultRoot.hash;
		defaultCompiler.update("model/Leaf.hx",
			"package model; struct Leaf { public var zero:Int = 0; public var absent:String; public var nullable:Null<Int> = null; " +
			"public var ratio:Float32 = 0.1; public var unsignedByte:UInt8 = 251; public var signedByte:Int8 = -128; " +
			"public var unsignedWord:UInt16 = 65535; public var signedWord:Int16 = -32768; }");
		var changedDefaultCompile = defaultCompiler.compile("Main"),
			changedDefaultRoot = requireDescriptor(defaultCompiler.lastTypedProgram.nativeTypeDescriptors, "model.Root"),
			changedUnsignedByte = descriptorField(descriptorField(changedDefaultRoot.fields, "leaf").fields, "unsignedByte").defaultValue;
		expect(changedUnsignedByte != null
			&& Type.enumEq(changedUnsignedByte.value, IntValue(251))
			&& changedDefaultRoot.hash != originalDefaultHash,
			"changing a nested narrow scalar default must change the recursive descriptor value and hash");
		expect(changedDefaultCompile.retyped.indexOf("Main.main") >= 0, "changing a field default in an imported module must invalidate typeInfo callers");
		defaultCompiler.update("model/Leaf.hx",
			"package model; struct Leaf { public var zero:Int = 0; public var absent:String; public var nullable:Null<Int>; " +
			"public var ratio:Float32 = 0.1; public var unsignedByte:UInt8 = 251; public var signedByte:Int8 = -128; " +
			"public var unsignedWord:UInt16 = 65535; public var signedWord:Int16 = -32768; }");
		var absentDefaultCompile = defaultCompiler.compile("Main"),
			absentDefaultRoot = requireDescriptor(defaultCompiler.lastTypedProgram.nativeTypeDescriptors, "model.Root"),
			absentNullable = descriptorField(descriptorField(absentDefaultRoot.fields, "leaf").fields, "nullable").defaultValue;
		expect(absentNullable == null && absentDefaultRoot.hash != changedDefaultRoot.hash,
			"removing an explicit null initializer must produce an absent default and change the nested descriptor hash");
		expect(absentDefaultCompile.retyped.indexOf("Main.main") >= 0, "removing an imported field default must invalidate typeInfo callers");
		var beforeFloat32Change = absentDefaultRoot.hash;
		defaultCompiler.update("model/Leaf.hx",
			"package model; struct Leaf { public var zero:Int = 0; public var absent:String; public var nullable:Null<Int>; " +
			"public var ratio:Float32 = 0.2; public var unsignedByte:UInt8 = 251; public var signedByte:Int8 = -128; " +
			"public var unsignedWord:UInt16 = 65535; public var signedWord:Int16 = -32768; }");
		var changedFloat32Compile = defaultCompiler.compile("Main"),
			changedFloat32Root = requireDescriptor(defaultCompiler.lastTypedProgram.nativeTypeDescriptors, "model.Root"),
			changedFloat32 = descriptorField(descriptorField(changedFloat32Root.fields, "leaf").fields, "ratio").defaultValue;
		expect(changedFloat32 != null
			&& Type.enumEq(changedFloat32.value, NativeTypeAnnotationValue.FloatValue(haxe.io.FPHelper.i32ToFloat(0x3E4CCCCD)))
			&& changedFloat32Root.hash != beforeFloat32Change
			&& changedFloat32Compile.retyped.indexOf("Main.main") >= 0,
			"changing a nested Float32 default must round to its declared precision and invalidate descriptor callers");
		if ([
			for (object in compiler.ir.IrProgramAssembler.objectsFrom(typed))
				if (object.name == "Pair" || object.name == "Outer") object
		].length != 0)
			throw "native value records must not be emitted as HashLink objects or HSTRUCT values";

		for (target in ["portable-abi32", "portable-abi64"]) {
			var imported = HxiParser.parse("native-layout.hxi",
				'interface native @target("$target") { struct Pair @layout(24, 8) { tag: u8 @offset(0); value: i64 @offset(8); ratio: f32 @offset(16); } }');
			HxiValidator.validate(imported, []);
			var importedLayout = HxiAbi.forInterface(imported).layout(HxiType.Named("Pair")),
				declaredLayout = requireLayout(pair.nativeLayouts, target);
			expect(importedLayout != null
				&& importedLayout.size == declaredLayout.size
				&& importedLayout.align == declaredLayout.alignment,
				'Haxe and imported HXI declarations must share $target size and alignment rules');
			switch imported.declarations[0] {
				case Structure("Pair", _, _, fields, _):
					for (nativeField in fields)
						expect(nativeField.offset == field(declaredLayout.fields, nativeField.name).offset,
							'Haxe and imported HXI declarations must agree on $target offsets for ${nativeField.name}');
				case _:
					throw "expected imported Pair layout";
			}
		}
		expectError('@:value @:repr("C") class Bad { public var label:String; }', "not an unmanaged native field type");
		expectError('@:value @:repr("C") class Bad { public var values:Array<Int>; }', "not an unmanaged native field type");
		expectError('@:value @:repr("C") class Bad { public function new() {} }', "instance methods or constructors");
		expectError('@:value @:repr("C") class Bad { public var self:Bad; }', "by-value layout cycle");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function consume(value:Pair):Void {}',
			"cannot be passed or stored as a Haxe runtime value yet");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function make():Pair return new Pair();',
			"cannot be returned as a Haxe runtime value yet");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function bad():Int return offsetof<Pair>("missing");', 'has no field "missing"');
		expectError('function bad():Int return sizeof<String>();', "no fixed native ABI layout");
		expectError('function bad():Int return offsetof<Int32>("x");', "requires a flat struct or native value record type");
		expectError('function bad():Int return typeInfo<String>().size;', "typeInfo requires a struct or legacy C value record");
		expectError('struct Bad { public var count:Int = next(); } function next():Int return 1;', "executable and computed defaults are unsupported");
		expectError('struct Bad { public var value:UInt8 = 256; } function main():Int return typeInfo<Bad>().hash.length;', "outside the range");
		expectError('struct Bad { public var value:UInt8 = -1; } function main():Int return typeInfo<Bad>().hash.length;', "outside the range");
		expectError('struct Bad { public var value:Int8 = 128; } function main():Int return typeInfo<Bad>().hash.length;', "outside the range");
		expectError('struct Bad { public var value:UInt16 = 65536; } function main():Int return typeInfo<Bad>().hash.length;', "outside the range");
		expectError('struct Bad { public var value:Int16 = -32769; } function main():Int return typeInfo<Bad>().hash.length;', "outside the range");
		expectError('struct Bad { public var value:Float32 = 3.5e38; } function main():Int return typeInfo<Bad>().hash.length;', "unsupported default");
		expectError('class Managed { public var x:Int32; }', "only appear in value structs");
		expectError('enum Managed { Value(value:Int32); }', "cannot be stored in a Haxe enum yet");
	}

	static function requireClass(classes:Array<compiler.types.TypedAst.TypedClass>, name:String):compiler.types.TypedAst.TypedClass {
		for (declaration in classes)
			if (declaration.name == name)
				return declaration;
		throw 'Missing typed class "$name"';
	}

	static function requireLayout(layouts:Array<compiler.types.TypedAst.TypedNativeLayout>, target:String):compiler.types.TypedAst.TypedNativeLayout {
		for (layout in layouts)
			if (layout.target == target)
				return layout;
		throw 'Missing native layout for "$target"';
	}

	static function requireDescriptor(descriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData>,
			name:String):compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData {
		for (descriptor in descriptors)
			if (descriptor.name == name)
				return descriptor;
		throw 'Missing native type descriptor "$name"';
	}

	static function descriptorField(fields:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorField>,
			name:String):compiler.types.NativeTypeDescriptor.NativeTypeDescriptorField {
		for (field in fields)
			if (field.name == name)
				return field;
		throw 'Missing descriptor field "$name"';
	}

	static function findDescriptorHash(strings:Array<String>):Null<String> {
		var hashPattern = new EReg("^[0-9a-f]{64}$", "");
		for (value in strings)
			if (hashPattern.match(value))
				return value;
		return null;
	}

	static function field(fields:Array<compiler.types.TypedAst.TypedNativeFieldLayout>, name:String):compiler.types.TypedAst.TypedNativeFieldLayout {
		for (layout in fields)
			if (layout.name == name)
				return layout;
		throw 'Missing native field "$name"';
	}

	static function constantReturn(functions:Array<compiler.types.TypedAst.TypedFunction>, name:String):Int {
		for (fn in functions)
			if (fn.name == name && fn.statements.length == 1)
				switch fn.statements[0] {
					case compiler.types.TypedAst.TypedStatement.TReturn(expression, _):
						switch expression.expression {
							case compiler.types.TypedAst.TypedExpressionKind.TIntLiteral(value): return value;
							case _: throw 'Function "$name" did not fold its layout query to an integer literal';
						}
					case _:
				}
		throw 'Missing constant-returning function "$name"';
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function expectError(source:String, expected:String):Void {
		try {
			Typer.typeLibrary(new Parser(new Lexer(new SourceFile("invalid-native-layout.hx", source)).tokenize()).parseProgram());
			throw 'expected native layout error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw error;
		}
	}

	static function expectDescriptorCodecError(action:Void->Void, expected:String):Void {
		try {
			action();
			throw 'expected descriptor codec error containing "$expected"';
		} catch (error:Dynamic)
			if (Std.string(error).indexOf(expected) < 0)
				throw error;
	}
}
