import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;
import compiler.runtime.CompilerIntrinsics;
import compiler.types.TypedAst.TypedExpressionKind;
import sys.io.File;

/** Verifies the first Haxe-owned C-layout model for HashLink type metadata. */
class HashlinkTypeMetadataMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("HashlinkTypeMetadata.hx",
			'import runtime.hashlink.HlType; import runtime.hashlink.HlTypeData; '
			+ 'import runtime.hashlink.HlTypeFunction; import runtime.hashlink.HlTypeFunction.HlTypeClosureType; '
			+ 'import runtime.hashlink.HlTypeFunction.HlTypeClosure; import runtime.hashlink.HlTypeObject; '
			+ 'import runtime.hashlink.HlTypeObject.HlObjectField; import runtime.hashlink.HlTypeObject.HlObjectProto; '
			+ 'import runtime.hashlink.HlTypeObject.HlTypeVirtual; import runtime.hashlink.HlTypeObject.HlTypeEnum; '
			+ 'import runtime.hashlink.HlTypeObject.HlEnumConstruct; import runtime.hashlink.HlModuleContext; '
			+ 'import runtime.hashlink.HlRuntimeObject; import runtime.hashlink.HlRuntimeObject.HlRuntimeBinding; '
			+ 'function typeSize():Int return sizeof<HlType>(); '
			+ 'function typeDataSize():Int return sizeof<HlTypeData>(); '
			+ 'function typeDataOffset():Int return offsetof<HlType>("data"); '
			+ 'function functionSize():Int return sizeof<HlTypeFunction>(); '
			+ 'function closureTypeSize():Int return sizeof<HlTypeClosureType>(); '
			+ 'function closureSize():Int return sizeof<HlTypeClosure>(); '
			+ 'function functionClosureOffset():Int return offsetof<HlTypeFunction>("closure"); '
			+ 'function objectSize():Int return sizeof<HlTypeObject>(); '
			+ 'function objectRuntimeOffset():Int return offsetof<HlTypeObject>("runtime"); '
			+ 'function fieldSize():Int return sizeof<HlObjectField>(); '
			+ 'function protoSize():Int return sizeof<HlObjectProto>(); '
			+ 'function virtualSize():Int return sizeof<HlTypeVirtual>(); '
			+ 'function enumSize():Int return sizeof<HlTypeEnum>(); '
			+ 'function enumConstructSize():Int return sizeof<HlEnumConstruct>(); '
			+ 'function moduleContextSize():Int return sizeof<HlModuleContext>(); '
			+ 'function runtimeObjectSize():Int return sizeof<HlRuntimeObject>(); '
			+ 'function runtimeBindingSize():Int return sizeof<HlRuntimeBinding>(); '
			+ 'function main():Int return typeSize() + typeDataSize() + typeDataOffset() + functionSize() + objectSize();');
		compiler.compile("HashlinkTypeMetadata");
		var functions = compiler.lastTypedProgram.functions;
		var imported = HxiParser.parse("HashLinkMetadata.hxi", File.getContent("stdlib/runtime/hashlink/HashLinkMetadata.hxi"));
		HxiValidator.validate(imported, []);
		var importedAbi = HxiAbi.forInterface(imported), layoutPairs = [
			{nativeName: "hl_alloc", haxeName: "runtime.hashlink.HlAllocation"},
			{nativeName: "hl_module_context", haxeName: "runtime.hashlink.HlModuleContext"},
			{nativeName: "hl_type_fun_closure_type", haxeName: "runtime.hashlink.HlTypeClosureType"},
			{nativeName: "hl_type_fun_closure", haxeName: "runtime.hashlink.HlTypeClosure"},
			{nativeName: "hl_type_fun", haxeName: "runtime.hashlink.HlTypeFunction"},
			{nativeName: "hl_obj_field", haxeName: "runtime.hashlink.HlObjectField"},
			{nativeName: "hl_obj_proto", haxeName: "runtime.hashlink.HlObjectProto"},
			{nativeName: "hl_type_obj", haxeName: "runtime.hashlink.HlTypeObject"},
			{nativeName: "hl_type_virtual", haxeName: "runtime.hashlink.HlTypeVirtual"},
			{nativeName: "hl_enum_construct", haxeName: "runtime.hashlink.HlEnumConstruct"},
			{nativeName: "hl_type_enum", haxeName: "runtime.hashlink.HlTypeEnum"},
			{nativeName: "hl_type", haxeName: "runtime.hashlink.HlType"}
		];
		for (pair in layoutPairs) {
			var importedLayout = importedAbi.layout(HxiType.Named(pair.nativeName)),
				haxeLayout = requireLayout(requireClass(compiler.lastTypedProgram.classes, pair.haxeName).nativeLayouts, "portable-abi64");
			expect(importedLayout != null && importedLayout.size == haxeLayout.size && importedLayout.align == haxeLayout.alignment,
				'${pair.haxeName} must match the header-derived HXI layout for ${pair.nativeName}');
		}
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeSize") == 40, "hl_type must match the 64-bit C header size");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataSize") == 8, "hl_type's anonymous union must be pointer-sized");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataOffset") == 8, "hl_type's union must follow the kind field with ABI alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionSize") == 80, "hl_type_fun must preserve nested aggregate padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.closureTypeSize") == 16, "hl_type_fun.closure_type must preserve pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.closureSize") == 32, "hl_type_fun.closure must preserve nested aggregate padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionClosureOffset") == 48, "hl_type_fun.closure must follow closure_type");
		expect(constantReturn(functions, "HashlinkTypeMetadata.objectSize") == 80, "hl_type_obj must preserve pointer alignment and tail padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.objectRuntimeOffset") == 72, "hl_type_obj.runtime must preserve pointer offsets");
		expect(constantReturn(functions, "HashlinkTypeMetadata.fieldSize") == 24, "hl_obj_field must preserve pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.protoSize") == 24, "hl_obj_proto must preserve tail padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.virtualSize") == 32, "hl_type_virtual must preserve lookup pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.enumSize") == 32, "hl_type_enum must preserve global value alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.enumConstructSize") == 40, "hl_enum_construct must preserve bool padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.moduleContextSize") == 24, "hl_module_context must preserve pointer slots");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeObjectSize") == 104, "hl_runtime_obj must preserve callback slots");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeBindingSize") == 24, "hl_runtime_binding must preserve tail padding");
		expectError('import runtime.hashlink.HlType; import runtime.memory.RawPtr; function bad(pointer:RawPtr<HlType>):Int return pointer.ref.missing; function main():Int return 0;',
			"Unknown native field");
	}

	static function constantReturn(functions:Array<compiler.types.TypedAst.TypedFunction>, name:String):Int {
		for (fn in functions)
			if (fn.name == name && fn.statements.length == 1)
				switch fn.statements[0] {
					case TReturn(expression, _):
						switch expression.expression {
							case TIntLiteral(value): return value;
							case _: throw 'Function "$name" did not fold its layout query to an integer literal';
						}
					case _:
				}
		throw 'Missing constant-returning function "$name"';
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

	static function expectError(source:String, expected:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("HashlinkTypeMetadataNegative.hx", source);
		try {
			compiler.compile("HashlinkTypeMetadataNegative");
			throw 'expected compile error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw error;
		}
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;
}
