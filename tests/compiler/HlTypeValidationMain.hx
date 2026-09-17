import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Verifies that packed metadata cannot point at a non-layout type. */
class HlTypeValidationMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.addSourceRoot("src");
		compiler.update("HlTypeValidationAdapter.hx",
			'import compiler.hl.HlCode; import compiler.hl.HlFunction; import compiler.hl.HlNativeMetadataBuilder; import compiler.hl.HlType; import compiler.hl.HlValidator; '
			+
			'import runtime.hashlink.HlTypeArena; import runtime.hashlink.HlTypeBuilder; import runtime.hashlink.HlTypeKind; import runtime.hashlink.HlTypeLayout; import runtime.memory.RawPtr; '
			+ 'function main():Int { '
			+
			'var code = new HlCode(); code.strings = ["PackedPrimitive", "value"]; code.types = [Simple(HlType.I32), Parameterized(HlType.Packed, 0), Function([], 0), Structure(0, 0, [{name: 1, type: 1}], [], [])]; '
			+ 'code.functions = [new HlFunction(2, 0, [0], [Return(0)])]; code.entryPoint = 0; '
			+
			'var validatorRejected = false; try { HlValidator.validate(code); } catch (error:Dynamic) validatorRejected = Std.string(error).indexOf("packed type parameter") >= 0; '
			+
			'var builderRejected = false; try { HlNativeMetadataBuilder.build(code); } catch (error:Dynamic) builderRejected = Std.string(error).indexOf("packed type parameter") >= 0; '
			+
			'var arena = new HlTypeArena(), builder = new HlTypeBuilder(arena), primitive = builder.primitive(HlTypeKind.Int32Type), packed = builder.parameterizedType(HlTypeKind.Packed, primitive), types = arena.allocTypePointerArray(1); types.store(packed); '
			+
			'var layoutRejected = false; try { HlTypeLayout.validate(types, 1); } catch (error:Dynamic) layoutRejected = Std.string(error).indexOf("packed type parameters") >= 0; arena.dispose(); '
			+ 'return validatorRejected && builderRejected && layoutRejected ? 42 : 1; }');
		try {
			var result = compiler.compile("HlTypeValidationAdapter"),
				output = "out/hashlink-type-validation.hl";
			File.saveBytes(output, HlWriter.encode(result.module));
			if (Sys.command(".tools/hashlink/hl", [output]) != 42)
				throw "Haxeon packed-type validation regression failed";
		} catch (error:CompileError)
			throw error.diagnostic.message;
	}
}
