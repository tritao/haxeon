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
			'import compiler.hl.HlCode; import compiler.hl.HlCode.HlTypeDef; import compiler.hl.HlHotReloadLoader; import compiler.hl.HlNativeMetadataBuilder; import compiler.hl.HlNativeModuleLoader; import compiler.hl.HlReader; import compiler.hl.HlWriter; '
			+ 'import compiler.hl.HlType; import runtime.hashlink.HlTypeBuilder; import runtime.hashlink.HlTypeKind; import runtime.hashlink.HlTypeBridge; '
			+
			'import runtime.hashlink.HlFunctionVersionTable; import runtime.hashlink.HlHotReloadState; import runtime.hashlink.HlMetadataGeneration; import runtime.hashlink.HlNativeModule; import runtime.memory.RawPtr; '
			+ 'import compiler.hl.persistence.HlRuntimeIdentity; '
			+ 'function main():Int { '
			+ 'var code = new HlCode(); '
			+ 'code.strings = ["Abstract", "BuilderObject", "value", "run", "BuilderEnum", "BuilderStruct", "Value", "std✓", "native"]; '
			+ 'code.types = [Simple(HlType.I32), Simple(HlType.Void), Function([0], 1), Method([0], 1), '
			+ 'Parameterized(HlType.Ref, 0), Parameterized(HlType.Null, 0), Structure(5, 1, [{name: 2, type: 0}], [], []), '
			+ 'Parameterized(HlType.Packed, 6), Abstract(0), Object(1, -1, 1, [{name: 2, type: 0}, {name: 3, type: 7}], '
			+ '[{name: 3, functionIndex: 0, prototype: 0}], []), Virtual([{name: 2, type: 0}]), Enum(4, 2, [{name: 6, params: [0, 4]}])]; '
			+ 'code.globals = [0, 0]; code.functions = [new compiler.hl.HlFunction(2, 0, [0, 0, 0, 0], '
			+ '[Call2(0, 1, 0, 3), Call3(0, 1, 0, 1, 2), CallN(0, 1, []), EnumField(0, 0, 0, 1), Return(0)], '
			+ '[{path: "metadata.hx", line: 42, column: 1, endLine: 42, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 1}, '
			+ '{path: "metadata.hx", line: 42, column: 1, endLine: 42, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 1}, '
			+ '{path: "metadata.hx", line: 43, column: 1, endLine: 43, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 1}, '
			+ '{path: "metadata.hx", line: 43, column: 1, endLine: 43, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 1}, '
			+ '{path: "metadata.hx", line: 44, column: 1, endLine: 44, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 1}], '
			+ '[{name: 8, position: 0, scopeEnd: 4}])]; '
			+ 'code.ints = [17]; code.floats = [2.5]; code.bytes = haxe.io.Bytes.ofString("xyz"); code.bytePositions = [1]; '
			+
			'code.functionIdentities = [{stableId: 73, functionIndex: 0, qualifiedName: "Builder.run", displayName: "run", sourcePath: "metadata.hx", start: 0, end: 4, line: 42, flags: 0}]; '
			+ 'code.debugSections = [{kind: 1, version: 1, flags: 0, payload: HlWriter.encodeFunctionIdentities(code.functionIdentities)}]; '
			+ 'code.natives = [{library: 7, name: 8, type: 2, functionIndex: 1}]; code.constants = [{global: 0, fields: [0, 1]}]; code.entryPoint = 0; '
			+
			'var loadCode = new HlCode(); loadCode.strings = ["haxeon_runtime", "native_pointer_size"]; loadCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; '
			+
			'loadCode.natives = [{library: 0, name: 1, type: 2, functionIndex: 1}]; loadCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [Call0(0, 1), Return(0)])]; '
			+
			'loadCode.functionIdentities = [{stableId: 101, functionIndex: 0, qualifiedName: "Loaded.main", displayName: "main", sourcePath: "loaded.hx", start: 0, end: 0, line: 1, flags: 0}]; '
			+
			'loadCode.debugSections = [{kind: 1, version: 1, flags: 0, payload: HlWriter.encodeFunctionIdentities(loadCode.functionIdentities)}]; loadCode.entryPoint = 0; '
			+
			'var loadedModule = HlNativeModuleLoader.load(HlWriter.encode(loadCode)), loadedValue = loadedModule.callI32(0), loadedModuleUnloaded = loadedModule.unload(); '
			+
			'var externalIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["main" => 0], ["main" => 101]), externalLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity), '
			+ 'externalValue = externalLoaded.callI32(101), externalUnloaded = externalLoaded.unload(); '
			+
			'var initializerIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["__init" => 0], ["__init" => 101]), initializerRejected = false; '
			+ 'try { HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), initializerIdentity); } catch (error:Dynamic) initializerRejected = true; '
			+
			'var patchCode = new HlCode(); patchCode.strings = ["haxeon_runtime", "native_pointer_size"]; patchCode.ints = [42]; patchCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; '
			+
			'patchCode.natives = [{library: 0, name: 1, type: 2, functionIndex: 1}]; patchCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [LoadInt(0, 0), Return(0)])]; patchCode.entryPoint = 0; '
			+
			'var patchTarget = HlNativeModuleLoader.load(HlWriter.encode(loadCode), null, HlNativeModule.PatchableFlag), patchOne = HlNativeModuleLoader.load(HlWriter.encode(patchCode), null, HlNativeModule.PatchableFlag), '
			+
			'patchRejected = !patchTarget.nativeModule.patchSlots(patchOne.nativeModule, [1]) && patchTarget.callI32(0) == 8, patchFirst = patchTarget.nativeModule.patchSlots(patchOne.nativeModule, [0]), patchValue = patchTarget.callI32(0); '
			+
			'patchCode.ints[0] = 43; var patchTwo = HlNativeModuleLoader.load(HlWriter.encode(patchCode), null, HlNativeModule.PatchableFlag), patchSecond = patchTarget.nativeModule.patchGeneration(patchTwo.nativeModule), '
			+ 'patchValueAgain = patchTarget.callI32(0), patchesUnloaded = patchTarget.unload() && patchOne.unload() && patchTwo.unload(); '
			+
			'var hotState = new HlHotReloadState(), stagedReload = HlHotReloadLoader.stage(hotState, HlWriter.encode(loadCode)), hotGeneration = stagedReload.commitNative(), '
			+
			'hotValue = hotGeneration.nativeModule == null ? -1 : hotGeneration.nativeModule.callI32(0), hotLoaded = hotGeneration.nativeModule != null && hotGeneration.nativeModule.isLoaded(), bytecodeVersions = HlFunctionVersionTable.fromMetadata(stagedReload.metadata, [101]); hotState.dispose(); '
			+
			'var generation = HlNativeMetadataBuilder.build(code), publication = generation.snapshot(), object = generation.type(9), native = publication.nativeDescriptors; '
			+ 'var kernel = new HlMetadataGeneration(128, 1), kernelInt = kernel.builder.primitive(HlTypeKind.Int32Type), '
			+
			'kernelFunction = kernel.builder.functionType([kernelInt], kernelInt), kernelRegs = kernel.arena.allocTypePointerArray(1), kernelOps = kernel.arena.allocOpcodeArray(1); '
			+
			'kernelRegs.store(kernelInt); kernelOps.ref.op = 67; kernelOps.ref.p1 = 0; kernelOps.ref.p2 = 0; kernelOps.ref.p3 = 0; kernelOps.ref.extra = RawPtr.nullPtr(); '
			+
			'kernel.addType(kernelInt); kernel.addType(kernelFunction); kernel.defineModule([RawPtr.nullPtr()], [kernelFunction]); kernel.defineGlobalTypes([kernelInt]); '
			+ 'kernel.addFunctionDescriptor({findex: 0, nregs: 1, nops: 1, reference: 0, nassigns: 0, type: kernelFunction, regs: kernelRegs, ops: kernelOps, '
			+ 'debug: RawPtr.nullPtr(), assigns: RawPtr.nullPtr(), object: RawPtr.nullPtr(), fieldName: RawPtr.nullPtr(), fieldReference: RawPtr.nullPtr()}); '
			+ 'kernel.publish(); '
			+
			'var kernelModule = new HlNativeModule(kernel), kernelInitialized = kernelModule.isLoaded(), kernelUnloaded = kernelModule.unload(); kernel.dispose(); '
			+ 'var correct = publication.typeCount == 12 && publication.usesContiguousTypes && publication.functionCount == 2 '
			+ '&& publication.globalCount == 2 && publication.globalTypes.offset(0).load() == generation.type(0) '
			+ '&& publication.globalTypes.offset(1).load() == generation.type(0) '
			+ '&& object.ref.data.ref.obj.ref.globalValue == publication.globals '
			+ '&& publication.nativeCode.ref.version == 7 && publication.nativeCode.ref.typeCount == 12 '
			+ '&& publication.nativeCode.ref.typeCapacity == 65536 && publication.nativeCode.ref.globalCount == 2 '
			+ '&& publication.nativeCode.ref.nativeCount == 1 && publication.nativeCode.ref.functionCount == 1 '
			+ '&& publication.nativeCode.ref.constantCount == 1 && publication.nativeCode.ref.debugSectionCount == 1 '
			+ '&& publication.nativeCode.ref.entryPoint == 0 && publication.nativeCode.ref.hasDebug '
			+ '&& publication.nativeCode.ref.ints == publication.ints && publication.nativeCode.ref.floats == publication.floats '
			+ '&& publication.nativeCode.ref.strings == publication.strings && publication.nativeCode.ref.ustrings == publication.ustrings '
			+ '&& publication.nativeCode.ref.types == publication.contiguousTypes && publication.nativeCode.ref.globals == publication.globalTypes '
			+
			'&& publication.nativeCode.ref.natives == publication.nativeDescriptors && publication.nativeCode.ref.functions == publication.functionDescriptors '
			+ '&& publication.nativeCode.ref.debugSections == publication.debugSections '
			+ '&& publication.functionStableIds == publication.nativeCode.ref.functionStableIds && publication.functionStableIds.load() == 73 '
			+ '&& publication.functionNames == publication.nativeCode.ref.functionNames && publication.functionNames.offset(0).load().offset(0).load() == 66 '
			+ '&& publication.functionNameLengths == publication.nativeCode.ref.functionNameLengths && publication.functionNameLengths.load() == 11 '
			+ '&& HlTypeBridge.native_metadata_validate_code(publication.nativeCode) == 12 '
			+ '&& kernelInitialized && kernelUnloaded '
			+
			'&& loadedValue == 8 && loadedModuleUnloaded && externalValue == 8 && externalUnloaded && initializerRejected && patchRejected && patchFirst && patchSecond && patchValue == 42 && patchValueAgain == 43 && patchesUnloaded '
			+ '&& hotValue == 8 && hotLoaded && bytecodeVersions.length() == 1 && bytecodeVersions.at(101).slot == 0 '
			+ '&& publication.constantCount == 1 && publication.constants.ref.global == 0 && publication.constants.ref.nfields == 2 '
			+ '&& publication.constants.ref.fields.load() == 0 && publication.constants.ref.fields.offset(1).load() == 1 '
			+ '&& HlTypeBridge.native_metadata_validate_constants(publication.constants, publication.constantCount, publication.globalCount) == 1 '
			+
			'&& publication.debugFileCount == 1 && publication.debugFiles.offset(0).load().offset(0).load() == 109 && publication.debugFileLengths.load() == 11 '
			+ '&& HlTypeBridge.native_metadata_validate_debug_files(publication.debugFiles, publication.debugFileCount) == 1 '
			+ '&& HlTypeBridge.native_metadata_validate_function_code(publication.functionDescriptors) == 5 '
			+ '&& HlTypeBridge.native_metadata_validate_global_types(publication.globalTypes, publication.globalCount, publication.globals) == 2 '
			+ '&& publication.intCount == 1 && publication.ints.load() == 17 && publication.floatCount == 1 && publication.floats.load() == 2.5 '
			+ '&& publication.stringCount == 9 && publication.stringLengths.offset(7).load() == 6 '
			+ '&& publication.bytes.load() == 120 && publication.byteCount == 3 && publication.bytePositionCount == 1 '
			+ '&& publication.bytePositions.load() == 1 && publication.entryPoint == 0 '
			+ '&& HlTypeBridge.native_metadata_validate_module_pools(publication.ints, publication.intCount, publication.floats, publication.floatCount, '
			+ 'publication.strings, publication.stringLengths, publication.stringCount, publication.bytes, publication.byteCount, '
			+ 'publication.bytePositions, publication.bytePositionCount, publication.entryPoint) == 9 '
			+ '&& publication.debugSectionCount == 1 && publication.debugSections.ref.kind == 1 && publication.debugSections.ref.version == 1 '
			+ '&& publication.debugSections.ref.flags == 0 '
			+ '&& publication.debugSections.ref.data.load() == 1 '
			+ '&& HlTypeBridge.native_metadata_validate_debug_sections(publication.debugSections, publication.debugSectionCount) == 1 '
			+ '&& HlTypeBridge.native_metadata_validate_function_debug(publication.functionDescriptors, publication.debugFileCount) == 1 '
			+ '&& publication.functionDescriptors.ref.debug.load() == 0 && publication.functionDescriptors.ref.debug.offset(1).load() == 42 '
			+ '&& publication.functionDescriptors.ref.debug.offset(2).load() == 0 && publication.functionDescriptors.ref.debug.offset(3).load() == 42 '
			+ '&& publication.functionDescriptors.ref.debug.offset(4).load() == 0 && publication.functionDescriptors.ref.debug.offset(5).load() == 43 '
			+ '&& publication.functionDescriptors.ref.assigns.load() == 8 && publication.functionDescriptors.ref.assigns.offset(1).load() == 0 '
			+ '&& publication.functionDescriptors.ref.assigns.offset(2).load() == 4 '
			+ '&& publication.functionDescriptors.ref.nops == 5 && publication.functionDescriptors.ref.ops.ref.op == 26 '
			+ '&& publication.functionDescriptors.ref.ops.ref.p1 == 0 && publication.functionDescriptors.ref.ops.ref.p2 == 1 '
			+ '&& publication.functionDescriptors.ref.ops.ref.p3 == 0 && !publication.functionDescriptors.ref.ops.ref.extra.isNull() '
			+ '&& publication.functionDescriptors.ref.ops.offset(1).ref.op == 27 '
			+ '&& publication.functionDescriptors.ref.ops.offset(1).ref.extra.load() == 1 '
			+ '&& publication.functionDescriptors.ref.ops.offset(2).ref.op == 29 '
			+ '&& publication.functionDescriptors.ref.ops.offset(2).ref.p3 == 0 '
			+ '&& publication.functionDescriptors.ref.ops.offset(2).ref.extra.isNull() '
			+ '&& publication.functionDescriptors.ref.ops.offset(3).ref.op == 93 '
			+ '&& !publication.functionDescriptors.ref.ops.offset(3).ref.extra.isNull() '
			+ '&& publication.functionDescriptors.ref.ops.offset(4).ref.op == 67 '
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
