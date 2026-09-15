import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Checks that the compiler-side HLB-to-native metadata adapter type-checks in the compiler graph. */
class HlNativeMetadataMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.addSourceRoot("src");
		compiler.update("HlNativeMetadataAdapter.hx",
			'import compiler.hl.HlCode; import compiler.hl.HlCode.HlTypeDef; import compiler.hl.HlNativeMetadataBuilder; '
			+ 'import compiler.hl.HlType; import runtime.hashlink.HlTypeBuilder; import runtime.hashlink.HlTypeKind; '
			+ 'function main():Int { '
			+ 'var code = new HlCode(); '
			+ 'code.strings = ["Abstract", "BuilderObject", "value", "run", "BuilderEnum", "BuilderStruct", "Value", "std✓", "native"]; '
			+ 'code.types = [Simple(HlType.I32), Simple(HlType.Void), Function([0], 1), Method([0], 1), '
			+ 'Parameterized(HlType.Ref, 0), Parameterized(HlType.Null, 0), Structure(5, 1, [{name: 2, type: 0}], [], []), '
			+ 'Parameterized(HlType.Packed, 6), Abstract(0), Object(1, -1, 1, [{name: 2, type: 0}, {name: 3, type: 7}], '
			+ '[{name: 3, functionIndex: 0, prototype: 0}], []), Virtual([{name: 2, type: 0}]), Enum(4, 2, [{name: 6, params: [0, 4]}])]; '
			+ 'code.globals = [0, 0]; code.functions = [new compiler.hl.HlFunction(2, 0, [0], [Return(0)])]; '
			+ 'code.natives = [{library: 7, name: 8, type: 2, functionIndex: 1}]; code.entryPoint = 0; '
			+
			'var generation = HlNativeMetadataBuilder.build(code), publication = generation.snapshot(), object = generation.type(9), native = publication.nativeDescriptors; '
			+ 'var correct = publication.typeCount == 12 && publication.usesContiguousTypes && publication.functionCount == 2 '
			+ '&& publication.globalCount == 2 && object.ref.data.ref.obj.ref.globalValue == publication.globals '
			+ '&& object.ref.kind == 11 && !object.ref.data.ref.obj.ref.runtime.isNull() '
			+ '&& object.ref.data.ref.obj.ref.fields.offset(1).ref.type.ref.kind == 22 '
			+ '&& native.ref.library.offset(3).load() == 226 && native.ref.library.offset(6).load() == 0 '
			+ '&& HlTypeBuilder.hashUtf16("value") == cast(object.ref.data.ref.obj.ref.fields.offset(0).ref.hashedName, Int); '
			+ 'generation.dispose(); return correct ? 42 : 1; }');
		try {
			var result = compiler.compile("HlNativeMetadataAdapter"),
				output = "out/hashlink-native-metadata-builder.hl";
			File.saveBytes(output, HlWriter.encode(result.module));
			if (Sys.command(".tools/hashlink/hl", [output]) != 42)
				throw "Haxeon-built HashLink metadata adapter did not execute successfully";
		} catch (error:CompileError)
			throw error.diagnostic.message;
	}
}
