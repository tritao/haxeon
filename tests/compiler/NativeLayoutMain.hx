import compiler.Diagnostic.CompileError;
import compiler.Compiler;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.Type.NominalKind;
import compiler.types.Type.CompilerType;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;

class NativeLayoutMain {
	static function main():Void {
		var source = '@:value @:repr("C") class Pair { public var tag:UInt8; public var value:Int64; public var ratio:Float32; } '
			+ '@:value @:repr("C") class Outer { public var first:Pair; public var second:Pair; } '
			+ '@:value @:repr("C") @:union class Payload { public var value:Int64; public var tag:UInt8; } '
			+ '@:value @:repr("C") class Fixed { @:array(3) public var values:UInt8; public var tail:Int32; } '
			+ '@:value @:repr("C") @:layout(8, 4) class Explicit { @:offset(4) public var value:Int32; } '
			+ '@:value @:repr("C") @:align(32) class OverAligned { public var value:Int32; } '
			+ '@:value @:repr("C") class LongValue { public var value:CLong; } '
			+ 'function pairSize():Int return sizeof<Pair>(); '
			+ 'function pairAlignment():Int return alignof<Pair>(); '
			+ 'function valueOffset():Int return offsetof<Pair>("value"); '
			+ 'function alignedSize():Int return sizeof<OverAligned>(); '
			+ 'function alignedAlignment():Int return alignof<OverAligned>(); '
			+ 'function longSize():Int return sizeof<CLong>();',
			program = new Parser(new Lexer(new SourceFile("native-layout.hx", source)).tokenize()).parseProgram(),
			typed = Typer.typeLibrary(program),
			pair = requireClass(typed.classes, "Pair"),
			outer = requireClass(typed.classes, "Outer"),
			payload = requireClass(typed.classes, "Payload"),
			fixed = requireClass(typed.classes, "Fixed"),
			explicit = requireClass(typed.classes, "Explicit"),
			overAligned = requireClass(typed.classes, "OverAligned"),
			longValue = requireClass(typed.classes, "LongValue");
		if (!pair.isNativeValue || pair.isValue || pair.nativeLayouts.length != 2)
			throw "C-represented values must be distinct typed declarations with per-ABI layouts";
		switch compiler.types.DeclarationIndex.validated(program).resolve(compiler.syntax.Ast.AstType.NamedType("Pair")) {
			case CompilerType.TInstance(NominalKind.NativeValue, "Pair", []):
			case _:
				throw "native value declarations resolved as managed classes";
		}
		var pair32 = requireLayout(pair.nativeLayouts, "portable-abi32"),
			pair64 = requireLayout(pair.nativeLayouts, "portable-abi64"),
			outer32 = requireLayout(outer.nativeLayouts, "portable-abi32"),
			outer64 = requireLayout(outer.nativeLayouts, "portable-abi64"),
			payload32 = requireLayout(payload.nativeLayouts, "portable-abi32"),
			payload64 = requireLayout(payload.nativeLayouts, "portable-abi64"),
			fixed32 = requireLayout(fixed.nativeLayouts, "portable-abi32"),
			fixed64 = requireLayout(fixed.nativeLayouts, "portable-abi64");
		expect(pair32.size == 16
			&& pair32.alignment == 4
			&& field(pair32.fields, "value").offset == 4
			&& field(pair32.fields, "ratio").offset == 12,
			"32-bit C record layout must align 64-bit integers to four bytes");
		expect(pair64.size == 24
			&& pair64.alignment == 8
			&& field(pair64.fields, "value").offset == 8
			&& field(pair64.fields, "ratio").offset == 16,
			"64-bit C record layout must preserve padding and field offsets");
		expect(outer32.size == 32
			&& field(outer32.fields, "second").offset == 16
			&& outer64.size == 48
			&& field(outer64.fields, "second").offset == 24,
			"nested native records must contribute their target-specific layout");
		expect(requireLayout(longValue.nativeLayouts, "portable-abi32").size == 4
			&& requireLayout(longValue.nativeLayouts, "portable-abi64").size == 8,
			"C long fields must follow the target ABI integer width");
		expect(payload.isNativeUnion
			&& payload32.size == 8
			&& payload32.alignment == 4
			&& field(payload32.fields, "value").offset == 0
			&& field(payload32.fields, "tag").offset == 0
			&& payload64.size == 8
			&& payload64.alignment == 8
			&& field(payload64.fields, "value").offset == 0
			&& field(payload64.fields, "tag").offset == 0,
			"native unions must overlap fields and use target-specific maximum size and alignment");
		expect(fixed.fields[0].nativeArrayLength == 3
			&& fixed32.size == 8
			&& fixed32.alignment == 4
			&& field(fixed32.fields, "values").offset == 0
			&& field(fixed32.fields, "values").size == 3
			&& field(fixed32.fields, "tail").offset == 4
			&& fixed64.size == 8
			&& field(fixed64.fields, "values").size == 3
			&& field(fixed64.fields, "tail").offset == 4,
			"native fixed arrays must occupy inline element storage and preserve following alignment");
		expect(requireLayout(explicit.nativeLayouts, "portable-abi32").size == 8
			&& field(requireLayout(explicit.nativeLayouts, "portable-abi32").fields, "value").offset == 4
			&& requireLayout(explicit.nativeLayouts, "portable-abi64").size == 8,
			"explicit native offsets and imported layout assertions must preserve C padding");
		expect(requireLayout(overAligned.nativeLayouts, "portable-abi32").size == 32
			&& requireLayout(overAligned.nativeLayouts, "portable-abi32").alignment == 32
			&& requireLayout(overAligned.nativeLayouts, "portable-abi64").size == 32
			&& requireLayout(overAligned.nativeLayouts, "portable-abi64").alignment == 32,
			"native records must preserve explicit alignment beyond the platform pointer width");
		var typed32 = Typer.typeLibrary(program, "portable-abi32"),
			typed64 = Typer.typeLibrary(program, "portable-abi64"),
			windows64 = Typer.typeLibrary(program, "x86_64-pc-windows-msvc");
		expect(constantReturn(typed32.functions, "pairSize") == 16
			&& constantReturn(typed32.functions, "pairAlignment") == 4
			&& constantReturn(typed32.functions, "valueOffset") == 4
			&& constantReturn(typed32.functions, "alignedSize") == 32
			&& constantReturn(typed32.functions, "alignedAlignment") == 32
			&& constantReturn(typed32.functions, "longSize") == 4,
			"native layout intrinsics must fold to the selected 32-bit ABI facts");
		expect(constantReturn(typed64.functions, "pairSize") == 24
			&& constantReturn(typed64.functions, "pairAlignment") == 8
			&& constantReturn(typed64.functions, "valueOffset") == 8
			&& constantReturn(typed64.functions, "alignedSize") == 32
			&& constantReturn(typed64.functions, "alignedAlignment") == 32
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
		expect(requireLayout(compiledPair.nativeLayouts, "portable-abi32").size == 16 && compiled.module.ints.indexOf(16) >= 0,
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
		if ([
			for (object in compiler.ir.IrProgramAssembler.objectsFrom(typed))
				if (object.name == "Pair" || object.name == "Outer") object
		].length != 0)
			throw "native value records must not be emitted as HashLink objects or HSTRUCT values";

		for (target in ["portable-abi32", "portable-abi64"]) {
			var imported = HxiParser.parse("native-layout.hxi",
				'interface native @target("$target") { struct Pair @layout(${target == "portable-abi32" ? "16, 4" : "24, 8"}) { tag: u8 @offset(0); value: i64 @offset(${target == "portable-abi32" ? "4" : "8"}); ratio: f32 @offset(${target == "portable-abi32" ? "12" : "16"}); } }');
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
		expectError('@:union class Bad { public var value:Int32; }', '@:union requires @:repr("C")');
		expectError('@:value @:repr("C") @:align(6) class Bad { public var value:Int32; }', "power of two");
		expectError('@:align(32) class Bad { public var value:Int32; }', "@:align requires @:repr(\"C\")");
		expectError('@:value @:repr("C") class Bad { @:array(0) public var values:UInt8; }', "positive integer argument");
		expectError('@:value @:repr("C") @:layout(4, 4) class Bad { @:offset(4) public var value:Int32; }', "expected imported size 4");
		expectError('class Bad { @:array(2) public var values:Int; }', "@:array fields require a native value record");
		expectError('@:value @:repr("C") class Bad { public function new() {} }', "instance methods or constructors");
		expectError('@:value @:repr("C") class Bad { public var self:Bad; }', "by-value layout cycle");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function consume(value:Pair):Void {}',
			"cannot be passed or stored as a Haxe runtime value yet");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function make():Pair return new Pair();',
			"cannot be returned as a Haxe runtime value yet");
		expectError('@:value @:repr("C") class Pair { public var x:Int32; } function bad():Int return offsetof<Pair>("missing");', 'has no field "missing"');
		expectError('function bad():Int return sizeof<String>();', "no fixed native ABI layout");
		expectError('function bad():Int return offsetof<Int32>("x");', "requires a native value record type");
		expectError('class Managed { public var x:Int32; }', "only appear in native value record fields");
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
}
