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
			'import compiler.Compiler; import compiler.Source.SourceFile; import compiler.runtime.CompilerIntrinsics; import compiler.hl.HlCode; import compiler.hl.HlCode.HlTypeDef; import compiler.hl.HlHotReloadLoader; import compiler.hl.HlNativeMetadataBuilder; import compiler.hl.HlNativeModuleLoader; import compiler.hl.HlReader; import compiler.hl.HlRuntimeModuleRegistry; import compiler.hl.HlRuntimePatchTransaction.HlRuntimePatchTransactionState; import compiler.hl.HlWriter; import runtime.RuntimeKernel; '
			+ 'import compiler.hl.patch.HlPatchWriter; '
			+ 'import compiler.hl.HlType; import runtime.hashlink.HlTypeBuilder; import runtime.hashlink.HlTypeKind; import runtime.hashlink.HlTypeBridge; '
			+
			'import runtime.hashlink.HlFunctionVersionTable; import runtime.hashlink.HlHotReloadState; import runtime.hashlink.HlMetadataGeneration; import runtime.hashlink.HlNativeModule; import runtime.memory.GcHandle; import runtime.memory.RawPtr; '
			+ 'import compiler.hl.persistence.HlRuntimeIdentity; '
			+
			'function patchIndex(input:haxe.io.BytesInput):Int { var first = input.readByte(); if ((first & 128) == 0) return first & 127; if ((first & 64) == 0) return input.readByte() | ((first & 31) << 8); return ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte(); } '
			+
			'function corruptPatchHash(bytes:haxe.io.Bytes):haxe.io.Bytes { var result = bytes.sub(0, bytes.length), input = new haxe.io.BytesInput(result); input.bigEndian = false; input.read(4); input.read(16); patchIndex(input); patchIndex(input); var sections = patchIndex(input); for (_ in 0...sections) { var tag = input.readByte(), length = patchIndex(input), start = input.position; input.read(length); if (tag == 1) { result.set(start, result.get(start) ^ 1); return result; } } throw "missing HLP symbols section"; } '
			+
			'function corruptPatchRegister(bytes:haxe.io.Bytes):haxe.io.Bytes { var result = bytes.sub(0, bytes.length), input = new haxe.io.BytesInput(result); input.bigEndian = false; input.read(4); input.read(16); patchIndex(input); patchIndex(input); var sections = patchIndex(input); for (_ in 0...sections) { var tag = input.readByte(), length = patchIndex(input), start = input.position; if (tag != 2) { input.read(length); continue; } patchIndex(input); patchIndex(input); patchIndex(input); var registers = patchIndex(input), instructions = patchIndex(input); for (_ in 0...registers) patchIndex(input); var opcode = input.readByte(); if (opcode != 1 || instructions == 0) throw "unexpected HLP test function"; result.set(input.position, 1); return result; } throw "missing HLP functions section"; } '
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
			'loadCode.natives = [{library: 0, name: 1, type: 2, functionIndex: 1}]; loadCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [Call0(0, 1), Return(0)], [{path: "loaded.hx", line: 1, column: 1, endLine: 1, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}, {path: "loaded.hx", line: 1, column: 1, endLine: 1, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}])]; '
			+
			'loadCode.functionIdentities = [{stableId: 101, functionIndex: 0, qualifiedName: "Loaded.main", displayName: "main", sourcePath: "loaded.hx", start: 0, end: 0, line: 1, flags: 0}]; '
			+
			'loadCode.debugSections = [{kind: 1, version: 1, flags: 0, payload: HlWriter.encodeFunctionIdentities(loadCode.functionIdentities)}]; loadCode.entryPoint = 0; '
			+
			'var generatedCompiler = new Compiler(); CompilerIntrinsics.register(generatedCompiler); generatedCompiler.update("Generated.hx", "function main():Int return 8;"); var generatedResult = generatedCompiler.compile("Generated"), generatedLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(generatedResult.module), generatedResult.runtimeIdentity), generatedValue = generatedLoaded.callI32(cast generatedResult.functionIds.get("main")), generatedUnloaded = generatedLoaded.unload(); '
			+
			'var runtimeRegistry = new HlRuntimeModuleRegistry(), registryFirst = runtimeRegistry.loadRuntime(HlWriter.encode(generatedResult.module), generatedResult.runtimeIdentity), registryFirstLoaded = registryFirst.isLoaded(), registryLease = runtimeRegistry.currentLease(), registrySecond = runtimeRegistry.loadRuntime(HlWriter.encode(generatedResult.module), generatedResult.runtimeIdentity), registrySecondLoaded = registrySecond.isLoaded(); var registryAcquireRejected = false; try { var registryUnexpectedLease = registryFirst.acquire(); registryUnexpectedLease.release(); } catch (error:Dynamic) registryAcquireRejected = true; var registryBlocked = runtimeRegistry.disposeRetired() == 0 && runtimeRegistry.retiredCount == 1 && runtimeRegistry.retiredBorrowedCount == 1; registryLease.release(); var registryReclaimed = runtimeRegistry.disposeRetired() == 1 && runtimeRegistry.retiredCount == 0 && registryLease.isReleased(), registryValue = runtimeRegistry.currentModule().callI32(cast generatedResult.functionIds.get("main")); runtimeRegistry.dispose(); var registryDisposed = true; '
			+
			'var loadedModule = HlNativeModuleLoader.load(HlWriter.encode(loadCode)), loadedValue = loadedModule.callI32(0), loadedModuleUnloaded = loadedModule.unload(); '
			+
			'var complexCode = new HlCode(); complexCode.strings = ["NativeObject", "value", "run", "NativeEnum"]; complexCode.ints = [42]; complexCode.types = [Simple(HlType.I32), Simple(HlType.Void), Function([0], 1), Object(0, -1, 1, [{name: 1, type: 0}], [{name: 2, functionIndex: 0, prototype: 0}], []), Virtual([{name: 1, type: 0}]), Enum(3, 2, [{name: 1, params: [0]}]), Function([], 0)]; complexCode.globals = [3, 5]; complexCode.constants = [{global: 0, fields: [0]}]; complexCode.functions = [new compiler.hl.HlFunction(6, 0, [3, 0], [GlobalGet(0, 0), FieldGet(1, 0, 0), Return(1)])]; complexCode.entryPoint = 0; var complexLoaded = HlNativeModuleLoader.load(HlWriter.encode(complexCode)), complexInitialized = complexLoaded.nativeModule.isLoaded(), complexValue = complexLoaded.nativeModule.callI32(0), complexUnloaded = complexLoaded.unload(), legacyBytes = HlWriter.encode(complexCode), legacyIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["main" => 0], ["main" => 101]), legacyLoaded = HlTypeBridge.native_runtime_module_load_bytes(legacyBytes, legacyIdentity), legacyValue = legacyLoaded == null ? -1 : HlTypeBridge.native_runtime_module_call_i32(legacyLoaded, 101), legacyUnloaded = legacyLoaded != null && HlTypeBridge.native_runtime_module_dispose(legacyLoaded) == 0; '
			+
			'var complexIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["main" => 0], ["main" => 202]), complexRuntimeLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(complexCode), complexIdentity), complexRuntimeValue = complexRuntimeLoaded.callI32(202), complexRuntimeUnloaded = complexRuntimeLoaded.unload(); complexUnloaded = complexUnloaded && complexRuntimeValue == 42 && complexRuntimeUnloaded; '
			+
			'var layoutCode = new HlCode(); layoutCode.strings = ["LayoutBase", "value", "LayoutPacked", "LayoutChild", "packed"]; layoutCode.types = [Simple(HlType.I32), Simple(HlType.Void), Function([0], 1), Object(0, -1, 1, [{name: 1, type: 0}], [], []), Structure(2, 0, [{name: 1, type: 0}], [], []), Parameterized(HlType.Packed, 4), Object(3, 3, 0, [{name: 4, type: 5}], [], [])]; layoutCode.globals = [3]; layoutCode.functions = [new compiler.hl.HlFunction(2, 0, [0], [Return(0)])]; layoutCode.entryPoint = 0; var layoutLoaded = HlNativeModuleLoader.load(HlWriter.encode(layoutCode)), layoutBase = layoutLoaded.metadata.type(3), layoutPacked = layoutLoaded.metadata.type(5), layoutChild = layoutLoaded.metadata.type(6), layoutBaseRuntime = layoutBase.ref.data.ref.obj.ref.runtime, layoutPackedRuntime = layoutPacked.ref.data.ref.typeParam.ref.data.ref.obj.ref.runtime, layoutChildRuntime = layoutChild.ref.data.ref.obj.ref.runtime, layoutInitialized = layoutBaseRuntime.ref.size == 16 && layoutBaseRuntime.ref.padSize == 4 && layoutBaseRuntime.ref.largestField == 8 && layoutBaseRuntime.ref.fieldIndexes.offset(0).load() == 8 && layoutPackedRuntime.ref.size == 4 && layoutPackedRuntime.ref.padSize == 0 && layoutPackedRuntime.ref.largestField == 4 && layoutPackedRuntime.ref.fieldIndexes.offset(0).load() == 0 && layoutChildRuntime.ref.parent == layoutBaseRuntime && layoutChildRuntime.ref.size == 16 && layoutChildRuntime.ref.padSize == 0 && layoutChildRuntime.ref.largestField == 8 && layoutChildRuntime.ref.nfields == 2 && layoutChildRuntime.ref.fieldIndexes.offset(0).load() == 8 && layoutChildRuntime.ref.fieldIndexes.offset(1).load() == 12 && layoutChild.ref.data.ref.obj.ref.globalValue == RawPtr.nullPtr() && layoutLoaded.metadata.globalType(0) == layoutBase; var layoutUnloaded = layoutLoaded.unload(); '
			+
			'var externalIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["main" => 0], ["main" => 101]), externalLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity), '
			+ 'externalValue = externalLoaded.callI32(101); '
			+
			'var initializerIdentity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["__init" => 0], ["__init" => 101]), initializerRejected = false; '
			+ 'try { HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), initializerIdentity); } catch (error:Dynamic) initializerRejected = true; '
			+
			'var patchCode = new HlCode(); patchCode.strings = ["haxeon_runtime", "native_pointer_size", "patch"]; patchCode.ints = [42]; patchCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0), Function([], 0)]; '
			+
			'patchCode.natives = [{library: 0, name: 1, type: 2, functionIndex: 1}]; patchCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [LoadInt(0, 0), Return(0)])]; patchCode.entryPoint = 0; '
			+
			'var externalPatch = HlPatchWriter.encode(patchCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 1, 2, 0, 0, 2, 3), externalHashRejected = false; try { externalLoaded.stagePatch(corruptPatchHash(externalPatch)); } catch (error:Dynamic) externalHashRejected = true; var externalRegisterRejected = false; try { externalLoaded.stagePatch(corruptPatchRegister(externalPatch)); } catch (error:Dynamic) externalRegisterRejected = true; var externalMalformedRejected = false; try { externalLoaded.stagePatch(externalPatch.sub(0, 21)); } catch (error:Dynamic) externalMalformedRejected = true; var externalUnknownIdentityRejected = false; try { externalLoaded.stagePatch(HlPatchWriter.encode(patchCode, haxe.io.Bytes.alloc(16), [0], [0 => 999], 2, 3, 0, 0, 2, 3)); } catch (error:Dynamic) externalUnknownIdentityRejected = true; var externalPatchInput = externalPatch.sub(0, externalPatch.length), externalStaleTransaction = externalLoaded.stagePatch(externalPatchInput), externalTransaction = externalLoaded.stagePatch(externalPatchInput); externalPatchInput.set(0, 0); externalTransaction.commit(); var externalPatchedValue = externalLoaded.callI32(101), externalCodeRevision = externalLoaded.committedPatchCodeRevision(0), externalMetadataTypeCount = externalLoaded.metadata.typeCount(), externalMetadataTypeKind:Int = cast externalLoaded.metadata.type(3).ref.kind, externalMetadataFunctionReturn = externalLoaded.metadata.type(3).ref.data.ref.fun.ref.ret == externalLoaded.metadata.type(0), externalMetadataString = externalLoaded.metadata.modulePoolsOrNull().string(2).offset(0).load() == 112 && externalLoaded.metadata.modulePoolsOrNull().string(2).offset(1).load() == 97, externalTransactionCommitted = externalTransaction.state == Committed && externalTransaction.patchBaseRevision == 1 && externalTransaction.patchRevision == 2, externalStaleRejected = false, externalPatchRejected = false, externalIdentityRejected = false, externalCallRejected = false; '
			+ 'externalTransaction.model.ints[0] = -1; var externalLedgerIsolated = externalLoaded.committedPatchGenerations()[0].patch.ints[0] == 42; '
			+
			'var growthLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity), growthCode = new HlCode(); growthCode.strings = ["haxeon_runtime", "native_pointer_size", "patch"]; growthCode.ints = [42, 43]; growthCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0), Function([], 0)]; growthCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [LoadInt(0, 1), Return(0)])]; growthCode.entryPoint = 0; var growthPatch = HlPatchWriter.encode(growthCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 2, 3, 1, 0, 3, 4); growthLoaded.patch(externalPatch); growthLoaded.patch(growthPatch); var growthValue = growthLoaded.callI32(101), growthRevision = growthLoaded.revision, growthPatches = growthLoaded.committedPatches().length, growthCodeRevision0 = growthLoaded.committedPatchCodeRevision(0), growthCodeRevision1 = growthLoaded.committedPatchCodeRevision(1), growthRetiredGeneration = growthLoaded.retiredPatchGenerations()[0], growthRetired = growthLoaded.retiredPatchCount == 1 && growthRetiredGeneration.revision == 2 && growthRetiredGeneration.isRetired && growthRetiredGeneration.activeFunctionCount == 0 && growthLoaded.committedPatchGenerations()[1].activeFunctionCount == 1, growthUnloaded = growthLoaded.unload(); '
			+
			'var failureLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity); failureLoaded.patch(externalPatch); var failureRejected = true; for (stage in 1...4) { failureLoaded.nativeModule.setPatchFailureStage(stage); try { failureLoaded.patch(growthPatch); failureRejected = false; } catch (error:Dynamic) {} if (failureLoaded.revision != 2 || failureLoaded.committedPatches().length != 1 || failureLoaded.retiredPatchCount != 0 || failureLoaded.callI32(101) != 42) failureRejected = false; } failureLoaded.patch(growthPatch); var failureRecovered = failureRejected && failureLoaded.revision == 3 && failureLoaded.callI32(101) == 43 && failureLoaded.retiredPatchCount == 1 && failureLoaded.unload(); '
			+
			'var relocationLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity), validRelocationValue:Int, validRelocationUnloaded:Bool; var externalRelocationRejected = false, relocationCode = new HlCode(); relocationCode.strings = ["haxeon_runtime", "native_pointer_size"]; relocationCode.ints = [8]; relocationCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; relocationCode.natives = [{library: 0, name: 1, type: 1, functionIndex: 1}]; relocationCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [Jump("return"), Call0(0, 1), Label("return"), LoadInt(0, 0), Return(0)])]; relocationCode.entryPoint = 0; relocationLoaded.patch(HlPatchWriter.encode(relocationCode, haxe.io.Bytes.alloc(16), [0], [0 => 101, 1 => 101], 1, 2, 0, 0, 2, 3)); validRelocationValue = relocationLoaded.callI32(101); validRelocationUnloaded = relocationLoaded.unload(); try { externalLoaded.stagePatch(HlPatchWriter.encode(relocationCode, haxe.io.Bytes.alloc(16), [0], [0 => 101, 1 => 999], 1, 2, 0, 0, 0, 2)); } catch (error:Dynamic) externalRelocationRejected = true; '
			+
			'var externalSlotRejected = false, wrongSlotCode = new HlCode(); wrongSlotCode.strings = ["haxeon_runtime", "native_pointer_size"]; wrongSlotCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; wrongSlotCode.functions = [new compiler.hl.HlFunction(1, 1, [0], [LoadInt(0, 0), Return(0)])]; wrongSlotCode.entryPoint = 1; try { externalLoaded.stagePatch(HlPatchWriter.encode(wrongSlotCode, haxe.io.Bytes.alloc(16), [1], [1 => 101], 2, 3, 0, 0, 2, 3)); } catch (error:Dynamic) externalSlotRejected = true; '
			+
			'var externalSignatureRejected = false, signatureCode = new HlCode(); signatureCode.strings = ["haxeon_runtime", "native_pointer_size"]; signatureCode.types = [Simple(HlType.I32), Function([], 0), Function([0], 0)]; signatureCode.functions = [new compiler.hl.HlFunction(2, 0, [0], [LoadInt(0, 0), Return(0)])]; signatureCode.entryPoint = 0; try { externalLoaded.stagePatch(HlPatchWriter.encode(signatureCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 2, 3, 0, 0, 2, 3)); } catch (error:Dynamic) externalSignatureRejected = true; '
			+
			'var externalDebugFileRejected = false, debugCode = new HlCode(); debugCode.strings = ["haxeon_runtime", "native_pointer_size"]; debugCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; debugCode.natives = [{library: 0, name: 1, type: 2, functionIndex: 1}]; debugCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [LoadInt(0, 0), Return(0)], [{path: "missing.hx", line: 1, column: 1, endLine: 1, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}, {path: "missing.hx", line: 1, column: 1, endLine: 1, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}])]; debugCode.entryPoint = 0; try { externalLoaded.stagePatch(HlPatchWriter.encode(debugCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 2, 3, 0, 0, 2, 3)); } catch (error:Dynamic) externalDebugFileRejected = true; '
			+
			'var externalDebugLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity), externalDebugCode = new HlCode(); externalDebugCode.strings = ["haxeon_runtime", "native_pointer_size"]; externalDebugCode.types = [Simple(HlType.I32), Function([], 0), Function([], 0)]; externalDebugCode.functions = [new compiler.hl.HlFunction(1, 0, [0], [Call0(0, 1), Return(0)], [{path: "loaded.hx", line: 2, column: 1, endLine: 2, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}, {path: "loaded.hx", line: 2, column: 1, endLine: 2, endColumn: 2, sourceHash: 0, start: null, end: null, flags: 0}])]; externalDebugCode.entryPoint = 0; var externalDebugPatch = HlPatchWriter.encode(externalDebugCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 1, 2, 0, 0, 2, 3), externalDebugTransaction = externalDebugLoaded.stagePatch(externalDebugPatch); externalDebugTransaction.commit(); var externalDebugValue = externalDebugLoaded.callI32(101), externalDebugUnloaded = externalDebugLoaded.unload(); '
			+
			'var externalDebugText = "debug runtime"; var externalDebugHash = new SourceFile("loaded.hx", externalDebugText).contentHash(); externalDebugCode.sourceSnapshots = [{sourceHash: externalDebugHash, content: haxe.io.Bytes.ofString(externalDebugText)}]; externalDebugCode.functions[0].debugLocations[0] = {path: "loaded.hx", line: 2, column: 1, endLine: 2, endColumn: 2, sourceHash: externalDebugHash, start: null, end: null, flags: 0}; externalDebugCode.functions[0].debugLocations[1] = {path: "loaded.hx", line: 2, column: 1, endLine: 2, endColumn: 2, sourceHash: externalDebugHash, start: null, end: null, flags: 0}; '
			+
			'externalDebugLoaded = HlNativeModuleLoader.loadRuntime(HlWriter.encode(loadCode), externalIdentity); externalDebugPatch = HlPatchWriter.encode(externalDebugCode, haxe.io.Bytes.alloc(16), [0], [0 => 101], 1, 2, 0, 0, 2, 3); externalDebugTransaction = externalDebugLoaded.stagePatch(externalDebugPatch); externalDebugTransaction.commit(); externalDebugValue = externalDebugLoaded.callI32(101); externalDebugUnloaded = externalDebugLoaded.unload(); '
			+
			'try { externalStaleTransaction.commit(); } catch (error:Dynamic) externalStaleRejected = true; externalStaleTransaction.rollback(); try { externalLoaded.patch(externalPatch); } catch (error:Dynamic) externalPatchRejected = true; try { externalLoaded.callI32(999); } catch (error:Dynamic) externalCallRejected = true; var externalRollback = externalLoaded.stagePatch(externalPatch); externalRollback.rollback(); var externalRolledBack = externalRollback.state == RolledBack, wrongModuleId = haxe.io.Bytes.alloc(16); wrongModuleId.set(0, 1); '
			+
			'try { externalLoaded.patch(HlPatchWriter.encode(patchCode, wrongModuleId, [0], [0 => 101], 2, 3, 0, 0, 2, 3)); } catch (error:Dynamic) externalIdentityRejected = true; var externalUnloaded = externalLoaded.unload(); '
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
			'var kernelModuleContext = kernel.defineModule([RawPtr.nullPtr()], [kernelFunction]), kernelObject = kernel.builder.objectType(kernel.builder.utf16Name("NativeObject"), RawPtr.nullPtr(), [{name: kernel.builder.utf16Name("value"), type: kernelInt, hashedName: HlTypeBuilder.hashUtf16("value")}], [], [], RawPtr.nullPtr(), kernelModuleContext, RawPtr.nullPtr()), '
			+
			'kernelEnum = kernel.builder.enumType(kernel.builder.utf16Name("NativeEnum"), [{name: kernel.builder.utf16Name("value"), parameters: [kernelInt], size: 0, hasPtr: false, offsets: [0]}], RawPtr.nullPtr()), '
			+
			'kernelVirtual = kernel.builder.virtualType([{name: kernel.builder.utf16Name("value"), type: kernelInt, hashedName: HlTypeBuilder.hashUtf16("value")}], 0, [0], RawPtr.nullPtr()); '
			+
			'kernel.addType(kernelInt); kernel.addType(kernelFunction); kernel.addType(kernelObject); kernel.addType(kernelEnum); kernel.addType(kernelVirtual); kernel.defineGlobalTypes([kernelInt]); '
			+ 'kernel.addFunctionDescriptor({findex: 0, nregs: 1, nops: 1, reference: 0, nassigns: 0, type: kernelFunction, regs: kernelRegs, ops: kernelOps, '
			+ 'debug: RawPtr.nullPtr(), assigns: RawPtr.nullPtr(), object: RawPtr.nullPtr(), fieldName: RawPtr.nullPtr(), fieldReference: RawPtr.nullPtr()}); '
			+ 'kernel.publish(); var kernelVirtualLookupBeforeInit = kernelVirtual.ref.data.ref.virtualType.ref.lookup; '
			+
			'var kernelModule = new HlNativeModule(kernel), kernelInitialized = kernelModule.isLoaded(), kernelRoot:GcHandle<String> = kernelModule.createGcHandle("owned"), kernelRootValue = kernelRoot.get() == "owned", kernelObjectInitialized = !kernelObject.ref.data.ref.obj.ref.runtime.isNull(), kernelEnumInitialized = kernelEnum.ref.data.ref.enumType.ref.constructs.offset(0).ref.size == 16 && kernelEnum.ref.data.ref.enumType.ref.constructs.offset(0).ref.offsets.offset(0).load() == 12, kernelVirtualInitialized = kernelVirtual.ref.data.ref.virtualType.ref.dataSize == 4 && !kernelVirtual.ref.data.ref.virtualType.ref.lookup.isNull() && kernelVirtual.ref.data.ref.virtualType.ref.lookup == kernelVirtualLookupBeforeInit, kernelUnloaded = kernelModule.unload(), kernelRootClosed = kernelRoot.isClosed(); kernel.dispose(); '
			+ 'var correct = publication.typeCount == 12 && publication.usesContiguousTypes && publication.functionCount == 2 '
			+ '&& publication.globalCount == 2 && publication.globalTypes.offset(0).load() == generation.type(0) '
			+ '&& publication.globalTypes.offset(1).load() == generation.type(0) '
			+ '&& object.ref.data.ref.obj.ref.globalValue == generation.globalIndex(1) '
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
			+ '&& object.ref.data.ref.obj.ref.module == publication.moduleContext '
			+ '&& publication.functionDescriptors.ref.object != object.ref.data.ref.obj '
			+ '&& publication.functionDescriptors.ref.object.ref.name.offset(0).load() == 0 '
			+ '&& publication.functionDescriptors.ref.field.ref.name.offset(0).load() == 105 '
			+ '&& publication.functionStableIds == publication.nativeCode.ref.functionStableIds && publication.functionStableIds.load() == 73 '
			+ '&& publication.functionNames == publication.nativeCode.ref.functionNames && publication.functionNames.offset(0).load().offset(0).load() == 66 '
			+ '&& publication.functionNameLengths == publication.nativeCode.ref.functionNameLengths && publication.functionNameLengths.load() == 11 '
			+ '&& generation.validateNativeCode() == 12 '
			+
			'&& kernelInitialized && kernelRootValue && kernelRootClosed && kernelObjectInitialized && kernelEnumInitialized && kernelVirtualInitialized && kernelUnloaded '
			+
			'&& generatedValue == 8 && generatedUnloaded && registryFirstLoaded && registrySecondLoaded && registryAcquireRejected && runtimeRegistry.generation == 2 && registryBlocked && registryReclaimed && registryValue == 8 && registryDisposed && loadedValue == 8 && loadedModuleUnloaded && complexInitialized && complexValue == 42 && complexUnloaded && legacyValue == 42 && legacyUnloaded && layoutInitialized && layoutUnloaded && externalHashRejected && externalRegisterRejected && externalMalformedRejected && externalUnknownIdentityRejected && externalRelocationRejected && externalSlotRejected && externalSignatureRejected && externalDebugFileRejected && externalValue == 8 && externalPatchedValue == 42 && externalTransactionCommitted && externalTransaction.model.functions.length == 1 && externalTransaction.model.functions[0].functionIndex == 101 && externalLoaded.committedPatches().length == 1 && externalLoaded.committedPatches()[0].revision == externalTransaction.model.revision && externalLoaded.committedPatches()[0].functions.length == externalTransaction.model.functions.length && externalLedgerIsolated && externalLoaded.committedPatchGenerations().length == 1 && externalLoaded.committedPatchGenerations()[0].baseRevision == 1 && externalLoaded.committedPatchGenerations()[0].revision == 2 && externalLoaded.committedPatchGenerations()[0].functions.at(101).generation == 2 && externalLoaded.committedPatchGenerations()[0].relocationStableIds.length == 0 && externalLoaded.functions.generation == 2 && externalLoaded.functions.at(101).generation == 2 && externalStaleRejected && externalRolledBack && externalLoaded.revision == 2 && externalPatchRejected && externalIdentityRejected && externalCallRejected && externalUnloaded && initializerRejected && patchRejected && patchFirst && patchSecond && patchValue == 42 && patchValueAgain == 43 && patchesUnloaded '
			+
			'&& growthValue == 43 && growthRevision == 3 && growthPatches == 2 && growthCodeRevision0 == 2 && growthCodeRevision1 == 3 && growthRetired && growthLoaded.committedPatchGenerations()[1].baseRevision == 2 && growthLoaded.committedPatchGenerations()[1].revision == 3 && growthLoaded.committedPatchGenerations()[1].functions.at(101).generation == 3 && growthUnloaded && failureRecovered && validRelocationValue > 0 && validRelocationUnloaded'
			+ '&& externalDebugValue == 8 && externalDebugUnloaded '
			+
			'&& externalCodeRevision == 2 && externalMetadataTypeCount == 4 && externalMetadataTypeKind == 10 && externalMetadataFunctionReturn && externalMetadataString '
			+ '&& hotValue == 8 && hotLoaded && bytecodeVersions.length() == 1 && bytecodeVersions.at(101).slot == 0 '
			+ '&& publication.constantCount == 1 && publication.constants.ref.global == 0 && publication.constants.ref.nfields == 2 '
			+ '&& publication.constants.ref.fields.load() == 0 && publication.constants.ref.fields.offset(1).load() == 1 '
			+ '&& generation.constantDescriptors.validate(publication.globalCount) == 1 '
			+
			'&& publication.debugFileCount == 1 && publication.debugFiles.offset(0).load().offset(0).load() == 109 && publication.debugFileLengths.load() == 11 '
			+ '&& generation.validateDebugFiles() == 1 '
			+ '&& generation.functionDescriptors.validateCodeAt(0) == 5 '
			+ '&& generation.validateGlobalTypes() == 2 '
			+ '&& publication.intCount == 1 && publication.ints.load() == 17 && publication.floatCount == 1 && publication.floats.load() == 2.5 '
			+ '&& publication.stringCount == 9 && publication.stringLengths.offset(7).load() == 6 '
			+ '&& publication.bytes.load() == 120 && publication.byteCount == 3 && publication.bytePositionCount == 1 '
			+ '&& publication.bytePositions.load() == 1 && publication.entryPoint == 0 '
			+ '&& generation.validateModulePools() == 9 '
			+ '&& publication.debugSectionCount == 1 && publication.debugSections.ref.kind == 1 && publication.debugSections.ref.version == 1 '
			+ '&& publication.debugSections.ref.flags == 0 '
			+ '&& publication.debugSections.ref.data.load() == 1 '
			+ '&& generation.debugSectionDescriptors.validate() == 1 '
			+ '&& generation.functionDescriptors.validateDebugAt(0, publication.debugFileCount) == 1 '
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
