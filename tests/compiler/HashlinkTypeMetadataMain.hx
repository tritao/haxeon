import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.types.TypedAst.TypedExpressionKind;

/** Verifies the first Haxe-owned C-layout model for HashLink type metadata. */
class HashlinkTypeMetadataMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("HashlinkTypeMetadata.hx",
			'import runtime.hashlink.HlType; import runtime.hashlink.HlTypeData; '
			+ 'import runtime.hashlink.HlTypeFunction; import runtime.hashlink.HlTypeObject; '
			+ 'function typeSize():Int return sizeof<HlType>(); '
			+ 'function typeDataSize():Int return sizeof<HlTypeData>(); '
			+ 'function typeDataOffset():Int return offsetof<HlType>("data"); '
			+ 'function functionSize():Int return sizeof<HlTypeFunction>(); '
			+ 'function objectSize():Int return sizeof<HlTypeObject>(); '
			+ 'function main():Int return typeSize() + typeDataSize() + typeDataOffset() + functionSize() + objectSize();');
		compiler.compile("HashlinkTypeMetadata");
		var functions = compiler.lastTypedProgram.functions;
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeSize") == 40, "hl_type must match the 64-bit C header size");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataSize") == 8, "hl_type's anonymous union must be pointer-sized");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataOffset") == 8, "hl_type's union must follow the kind field with ABI alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionSize") == 80, "hl_type_fun must preserve nested aggregate padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.objectSize") == 80, "hl_type_obj must preserve pointer alignment and tail padding");
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
