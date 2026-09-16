package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlValidator;
import compiler.hl.HlOpcode;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlWriter;
import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchFunction;
import compiler.hl.patch.HlPatch.HlPatchInstruction;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataTypeAppend;
import runtime.hashlink.HlRuntimePatchFunctions;
import runtime.hashlink.HlPatchDebug.HlRuntimePatchDebug;
import runtime.hashlink.HlPatchDebug.HlSourceSpan;
import runtime.hashlink.HlPatchResolution.HlRuntimePatchResolution;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlTypeKind;
import runtime.memory.NativeString;
import runtime.memory.RawPtr;
import runtime.hashlink.HlPatchInput.HlRuntimePatchInput;
import runtime.hashlink.HlPatchInput.HlRuntimePatchFunctionInput;
import runtime.hashlink.HlPatchInput.HlRuntimePatchInstruction;

/** Imports one validated HLB module into Haxe-owned HashLink metadata. */
class HlNativeMetadataBuilder {
	/**
		Build, derive, and publish the native metadata graph for one HLB module.

		When supplied, functionPointers is indexed by the module's dispatch slot;
		missing slots are represented by null pointers until native code is
		installed. The returned generation owns every imported allocation.
	 */
	public static function build(code:HlCode, ?functionPointers:Array<RawPtr<UInt8>>):HlMetadataGeneration {
		return buildModule(new HlModule(code), functionPointers);
	}

	/** Build metadata from the validated Haxe-owned module model. */
	public static function buildModule(module:HlModule, ?functionPointers:Array<RawPtr<UInt8>>):HlMetadataGeneration {
		if (module == null)
			throw "HashLink native metadata requires an HLB module";
		var code = module.code;
		var generation = new HlMetadataGeneration(65536, positive(code.types.length), 65536, positive(code.functions.length), positive(code.natives.length),
			positive(code.constants.length), positive(code.debugSections.length));
		try {
			var typePointers = allocateTypes(code, generation),
				functionCount = dispatchSlotCount(code),
				pointers = dispatchPointers(functionCount, functionPointers),
				functionTypes = dispatchTypes(code, typePointers, functionCount),
				moduleContext = generation.defineModule(pointers, functionTypes),
				globals = generation.defineGlobalTypes([for (global in code.globals) typePointers[global]]);
			generation.defineModulePools(new runtime.hashlink.HlModulePools(generation.arena, generation.builder, code.ints, code.floats, code.strings,
				code.bytes, code.bytePositions, code.entryPoint));
			generation.defineDebugFiles(debugFilePaths(code));
			for (section in code.debugSections)
				generation.addDebugSection({
					kind: section.kind,
					version: section.version,
					flags: section.flags,
					payload: section.payload
				});
			for (index in 0...code.types.length)
				generation.addType(typePointers[index]);
			defineTypes(code, generation, typePointers, moduleContext, globals);
			addFunctionDescriptors(code, generation, typePointers);
			defineFunctionIdentities(module, generation);
			addNativeDescriptors(code, generation, typePointers);
			addConstants(code, generation);
			generation.publish();
			return generation;
		} catch (error:Dynamic) {
			generation.dispose();
			throw error;
		}
	}

	/** Prepare compatible appended patch types in the published Haxe-owned arena. */
	public static function preparePatchTypes(module:HlModule, generation:HlMetadataGeneration, patch:HlPatch):HlMetadataTypeAppend {
		if (module == null || generation == null || patch == null)
			throw "HashLink patch type preparation requires a module, generation, and patch";
		if (patch.baseTypes != generation.typeCount())
			throw 'HashLink patch type base ${patch.baseTypes} does not match the live metadata count ${generation.typeCount()}';
		var append = generation.beginTypeAppend(),
			baseTypes:Array<RawPtr<runtime.hashlink.HlType>> = [];
		try {
			for (index in 0...patch.baseTypes)
				baseTypes.push(generation.type(index));
			var appended:Array<RawPtr<runtime.hashlink.HlType>> = [];
			for (definition in patch.types) {
				var type = allocatePatchType(module, patch, generation.builder, definition);
				appended.push(type);
				append.add(type);
			}
			var allTypes = baseTypes.concat(appended);
			for (index in 0...patch.types.length)
				definePatchType(generation.builder, appended[index], patch.types[index], allTypes);
			return append;
		} catch (error:Dynamic) {
			append.rollback();
			throw error;
		}
	}

	/** Prepare cumulative scalar pools in the published metadata arena. */
	public static function preparePatchPools(module:HlModule, generation:HlMetadataGeneration, patch:HlPatch):RawPtr<runtime.hashlink.HlPatchPools> {
		if (module == null || generation == null || patch == null)
			throw "HashLink patch pool preparation requires a module, generation, and patch";
		if (patch.baseInts != module.code.ints.length
			|| patch.baseFloats != module.code.floats.length
			|| patch.baseStrings != module.code.strings.length)
			throw "HashLink patch pool bases do not match the live module";
		var current = generation.modulePoolsOrNull();
		if (current == null)
			throw "HashLink patch pool preparation requires existing module pools";
		var pools = new runtime.hashlink.HlModulePools(generation.arena, generation.builder, module.code.ints.concat(patch.ints),
			module.code.floats.concat(patch.floats), module.code.strings.concat(patch.strings), module.code.bytes, module.code.bytePositions,
			module.code.entryPoint),
			descriptor = generation.arena.allocPatchPools();
		descriptor.ref.intCount = cast pools.intCount;
		descriptor.ref.floatCount = cast pools.floatCount;
		descriptor.ref.stringCount = cast pools.stringCount;
		descriptor.ref.ints = pools.ints;
		descriptor.ref.floats = pools.floats;
		descriptor.ref.strings = pools.strings;
		descriptor.ref.stringLengths = pools.stringLengths;
		descriptor.ref.ustrings = pools.ustrings;
		generation.replaceModulePools(pools);
		return descriptor;
	}

	/** Prepare patch function descriptors and opcode storage in the metadata arena. */
	public static function preparePatchFunctions(generation:HlMetadataGeneration, patch:HlPatch, identity:HlRuntimeManifest):HlRuntimePatchFunctions {
		if (generation == null || patch == null || identity == null)
			throw "HashLink patch function preparation requires a generation, patch, and runtime identity";
		var typeCount = generation.typeCount();
		if (typeCount != patch.baseTypes + patch.types.length)
			throw 'HashLink patch function types require $typeCount records, got ${patch.baseTypes + patch.types.length}';
		if (patch.functions.length == 0)
			throw "HashLink patch function preparation requires at least one function";
		var descriptors = generation.arena.allocFunctionArray(patch.functions.length);
		for (index in 0...patch.functions.length)
			writePatchFunction(descriptors.offset(index), generation, patch, patch.functions[index], typeCount, identity);
		return new HlRuntimePatchFunctions(descriptors, patch.functions.length);
	}

	/** Prepare Haxe-resolved stable-ID and relocation slots for native validation. */
	public static function preparePatchResolution(generation:HlMetadataGeneration, patch:HlPatch, identity:HlRuntimeManifest):RawPtr<HlRuntimePatchResolution> {
		if (generation == null || patch == null || identity == null)
			throw "HashLink patch resolution requires a generation, patch, and runtime identity";
		if (patch.functions.length == 0)
			throw "HashLink patch resolution requires at least one function";
		var functions = generation.arena.allocPatchFunctionResolutionArray(patch.functions.length);
		for (index in 0...patch.functions.length) {
			var source = patch.functions[index],
				destination = functions.offset(index),
				expectedSlot = identitySlot(identity, source.functionIndex);
			if (expectedSlot < 0 || expectedSlot != source.slot)
				throw 'HashLink patch resolution has an invalid slot for function identity ${source.functionIndex}';
			destination.ref.stableId = cast source.functionIndex;
			destination.ref.slot = cast source.slot;
			destination.ref.relocationCount = cast source.relocations.length;
			if (source.relocations.length == 0) {
				destination.ref.relocationStableIds = RawPtr.nullPtr();
				destination.ref.relocationSlots = RawPtr.nullPtr();
				continue;
			}
			var stableIds = generation.arena.allocInt32Array(source.relocations.length),
				slots = generation.arena.allocInt32Array(source.relocations.length);
			for (relocationIndex in 0...source.relocations.length) {
				var relocation = source.relocations[relocationIndex],
					targetSlot = identitySlot(identity, relocation.stableId);
				if (targetSlot < 0)
					throw 'HashLink patch resolution references unknown function identity ${relocation.stableId}';
				stableIds.offset(relocationIndex).store(cast relocation.stableId);
				slots.offset(relocationIndex).store(cast targetSlot);
			}
			destination.ref.relocationStableIds = stableIds;
			destination.ref.relocationSlots = slots;
		}
		var result = generation.arena.allocPatchResolution();
		result.ref.functionCount = cast patch.functions.length;
		result.ref.functions = functions;
		return result;
	}

	/** Project the decoded HLP model into an arena-owned native patch input. */
	public static function preparePatchInput(generation:HlMetadataGeneration, patch:HlPatch, debug:RawPtr<HlRuntimePatchDebug>,
			resolution:RawPtr<HlRuntimePatchResolution>):RawPtr<HlRuntimePatchInput> {
		if (generation == null || patch == null || debug.isNull() || resolution.isNull())
			throw "HashLink patch input requires a generation, patch, debug metadata, and resolution metadata";
		if (cast(resolution.ref.functionCount, Int) != patch.functions.length
			|| (patch.functions.length > 0 && resolution.ref.functions.isNull()))
			throw "HashLink patch input resolution count does not match the patch";
		if (patch.moduleId == null || patch.moduleId.length != 16)
			throw "HashLink patch input requires a 16-byte module identity";
		var moduleId = generation.arena.allocUInt8Array(16);
		for (index in 0...16)
			moduleId.offset(index).store(cast patch.moduleId.get(index));

		var ints:RawPtr<Int32> = patch.ints.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(patch.ints.length);
		for (index in 0...patch.ints.length)
			ints.offset(index).store(cast patch.ints[index]);
		var floats:RawPtr<Float> = patch.floats.length == 0 ? RawPtr.nullPtr() : generation.arena.allocFloat64Array(patch.floats.length);
		for (index in 0...patch.floats.length)
			floats.offset(index).store(patch.floats[index]);
		var strings:RawPtr<RawPtr<UInt8>> = patch.strings.length == 0 ? RawPtr.nullPtr() : generation.arena.allocNativePointerArray(patch.strings.length),
			stringLengths:RawPtr<Int32> = patch.strings.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(patch.strings.length);
		for (index in 0...patch.strings.length) {
			var bytes = NativeString.utf8Bytes(patch.strings[index]),
				pointer = generation.arena.allocUInt8Array(bytes.length + 1);
			for (byte in 0...bytes.length)
				pointer.offset(byte).store(cast bytes[byte]);
			pointer.offset(bytes.length).store(cast 0);
			strings.offset(index).store(pointer);
			stringLengths.offset(index).store(cast bytes.length);
		}

		var debugFiles:RawPtr<RawPtr<UInt8>> = patch.debugFiles.length == 0 ? RawPtr.nullPtr() : generation.arena.allocNativePointerArray(patch.debugFiles.length),
			debugFileLengths:RawPtr<Int32> = patch.debugFiles.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(patch.debugFiles.length);
		for (index in 0...patch.debugFiles.length) {
			var debugBytes = NativeString.utf8Bytes(patch.debugFiles[index]),
				debugPointer = generation.arena.allocUInt8Array(debugBytes.length + 1);
			for (byte in 0...debugBytes.length)
				debugPointer.offset(byte).store(cast debugBytes[byte]);
			debugPointer.offset(debugBytes.length).store(cast 0);
			debugFiles.offset(index).store(debugPointer);
			debugFileLengths.offset(index).store(cast debugBytes.length);
		}

		var functions = generation.arena.allocPatchFunctionInputArray(patch.functions.length);
		for (index in 0...patch.functions.length) {
			var source = patch.functions[index],
				destination = functions.offset(index),
				resolved = resolution.ref.functions.offset(index);
			if (cast(resolved.ref.stableId, Int) != source.functionIndex
				|| cast(resolved.ref.slot, Int) != source.slot || cast(resolved.ref.relocationCount, Int) != source.relocations.length)
				throw 'HashLink patch input resolution does not match function identity ${source.functionIndex}';
			if (source.relocations.length > 0 && (resolved.ref.relocationStableIds.isNull() || resolved.ref.relocationSlots.isNull()))
				throw 'HashLink patch input resolution has no relocation slots for function identity ${source.functionIndex}';
			var registerStorage:RawPtr<Int32> = source.registers.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(source.registers.length),
				instructionStorage:RawPtr<HlRuntimePatchInstruction> = source.instructions.length == 0 ? RawPtr.nullPtr() : generation.arena.allocPatchInstructionArray(source.instructions.length),
				relocationInstructions:RawPtr<Int32> = source.relocations.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(source.relocations.length),
				relocationStableIds:RawPtr<Int32> = source.relocations.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(source.relocations.length),
				debugSpans:RawPtr<HlSourceSpan> = source.debug.length == 0 ? RawPtr.nullPtr() : generation.arena.allocSourceSpanArray(source.debug.length);
			destination.ref.type = cast source.type;
			destination.ref.stableId = cast source.functionIndex;
			destination.ref.slot = cast source.slot;
			destination.ref.registerCount = cast source.registers.length;
			destination.ref.registers = registerStorage;
			for (register in 0...source.registers.length)
				registerStorage.offset(register).store(cast source.registers[register]);
			destination.ref.instructionCount = cast source.instructions.length;
			destination.ref.instructions = instructionStorage;
			for (instructionIndex in 0...source.instructions.length) {
				var instruction = source.instructions[instructionIndex],
					instructionDestination = instructionStorage.offset(instructionIndex),
					operands:RawPtr<Int32> = instruction.operands.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(instruction.operands.length);
				instructionDestination.ref.opcode = cast instruction.opcode;
				instructionDestination.ref.operandCount = cast instruction.operands.length;
				instructionDestination.ref.operands = operands;
				for (operand in 0...instruction.operands.length)
					operands.offset(operand).store(cast instruction.operands[operand]);
			}
			destination.ref.relocationCount = cast source.relocations.length;
			destination.ref.relocationInstructions = relocationInstructions;
			destination.ref.relocationStableIds = relocationStableIds;
			for (relocation in 0...source.relocations.length) {
				var relocationModel = source.relocations[relocation],
					resolvedStableId:Int = cast(resolved.ref.relocationStableIds.offset(relocation).load(), Int),
					resolvedSlot:Int = cast(resolved.ref.relocationSlots.offset(relocation).load(), Int);
				if (resolvedStableId != relocationModel.stableId)
					throw 'HashLink patch input relocation identity does not match function identity ${source.functionIndex}';
				if (relocationModel.instruction < 0 || relocationModel.instruction >= source.instructions.length)
					throw 'HashLink patch input relocation instruction is out of range for function identity ${source.functionIndex}';
				var relocationInstruction = instructionStorage.offset(relocationModel.instruction);
				if (cast(relocationInstruction.ref.operandCount, Int) < 2 || relocationInstruction.ref.operands.isNull())
					throw 'HashLink patch input relocation instruction has no target operand for function identity ${source.functionIndex}';
				relocationInstruction.ref.operands.offset(1).store(cast resolvedSlot);
				relocationInstructions.offset(relocation).store(cast relocationModel.instruction);
				relocationStableIds.offset(relocation).store(cast relocationModel.stableId);
			}
			destination.ref.debugCount = cast source.debug.length;
			destination.ref.debugSpans = debugSpans;
			for (locationIndex in 0...source.debug.length) {
				var sourceLocation = source.debug[locationIndex],
					location = debugSpans.offset(locationIndex);
				location.ref.file = cast sourceLocation.file;
				location.ref.line = cast sourceLocation.line;
				location.ref.column = cast sourceLocation.column;
				location.ref.endLine = cast sourceLocation.endLine;
				location.ref.endColumn = cast sourceLocation.endColumn;
				location.ref.sourceHash = cast sourceLocation.sourceHash;
				location.ref.start = cast sourceLocation.start;
				location.ref.end = cast sourceLocation.end;
				location.ref.flags = cast sourceLocation.flags;
			}
		}

		var result = generation.arena.allocPatchInput();
		result.ref.moduleId = moduleId;
		result.ref.baseRevision = cast patch.baseRevision;
		result.ref.revision = cast patch.revision;
		result.ref.intPrefixHash = cast patch.intPrefixHash;
		result.ref.floatPrefixHash = cast patch.floatPrefixHash;
		result.ref.stringPrefixHash = cast patch.stringPrefixHash;
		result.ref.typePrefixHash = cast patch.typePrefixHash;
		result.ref.baseIntCount = cast patch.baseInts;
		result.ref.intCount = cast patch.ints.length;
		result.ref.ints = ints;
		result.ref.floatCount = cast patch.floats.length;
		result.ref.baseFloatCount = cast patch.baseFloats;
		result.ref.floats = floats;
		result.ref.stringCount = cast patch.strings.length;
		result.ref.baseStringCount = cast patch.baseStrings;
		result.ref.strings = strings;
		result.ref.stringLengths = stringLengths;
		result.ref.typeCount = cast patch.types.length;
		result.ref.baseTypeCount = cast patch.baseTypes;
		result.ref.functionCount = cast patch.functions.length;
		result.ref.functions = functions;
		result.ref.debugFileCount = cast patch.debugFiles.length;
		result.ref.debugFiles = debugFiles;
		result.ref.debugFileLengths = debugFileLengths;
		result.ref.sourceSnapshotCount = cast patch.sourceSnapshots.length;
		result.ref.sourceSnapshots = debug.ref.snapshots;
		return result;
	}

	/** Prepare source spans and snapshots in the metadata arena. */
	public static function preparePatchDebug(generation:HlMetadataGeneration, patch:HlPatch):RawPtr<HlRuntimePatchDebug> {
		if (generation == null || patch == null)
			throw "HashLink patch debug preparation requires a generation and patch";
		var spans = generation.arena.allocSourceSpanPointerArray(patch.functions.length);
		for (index in 0...patch.functions.length) {
			var source = patch.functions[index].debug;
			if (source.length == 0) {
				spans.offset(index).store(RawPtr.nullPtr());
				continue;
			}
			if (source.length != patch.functions[index].instructions.length)
				throw 'HashLink patch debug count does not match function ${patch.functions[index].functionIndex} opcodes';
			var destination = generation.arena.allocSourceSpanArray(source.length);
			for (opcode in 0...source.length) {
				var location = source[opcode];
				if (location.file < 0 || location.file >= patch.debugFiles.length)
					throw 'HashLink patch function ${patch.functions[index].functionIndex} has an invalid debug file index';
				var file = generation.debugFileIndex(patch.debugFiles[location.file]);
				if (file < 0)
					throw 'HashLink patch debug file "${patch.debugFiles[location.file]}" is not present in the loaded module';
				var span = destination.offset(opcode);
				span.ref.file = cast file;
				span.ref.line = cast location.line;
				span.ref.column = cast location.column;
				span.ref.endLine = cast location.endLine;
				span.ref.endColumn = cast location.endColumn;
				span.ref.sourceHash = cast location.sourceHash;
				span.ref.start = cast location.start;
				span.ref.end = cast location.end;
				span.ref.flags = cast location.flags;
			}
			spans.offset(index).store(destination);
		}

		var snapshots:RawPtr<runtime.hashlink.HlPatchDebug.HlSourceSnapshot> = patch.sourceSnapshots.length == 0 ? RawPtr.nullPtr() : generation.arena.allocSourceSnapshotArray(patch.sourceSnapshots.length);
		for (index in 0...patch.sourceSnapshots.length) {
			var source = patch.sourceSnapshots[index];
			if (source.sourceHash == 0 || source.content == null)
				throw "HashLink patch source snapshot is incomplete";
			var content:RawPtr<UInt8> = source.content.length == 0 ? RawPtr.nullPtr() : generation.arena.allocUInt8Array(source.content.length);
			for (byte in 0...source.content.length)
				content.offset(byte).store(cast source.content.get(byte));
			var destination = snapshots.offset(index);
			destination.ref.sourceHash = cast source.sourceHash;
			destination.ref.length = cast source.content.length;
			destination.ref.content = content;
		}
		var descriptor = generation.arena.allocPatchDebug();
		descriptor.ref.functionCount = cast patch.functions.length;
		descriptor.ref.spans = spans;
		descriptor.ref.snapshotCount = cast patch.sourceSnapshots.length;
		descriptor.ref.snapshots = snapshots;
		return descriptor;
	}

	static function allocateTypes(code:HlCode, generation:HlMetadataGeneration):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (definition in code.types)
			result.push(allocateType(code, generation.builder, definition));
		return result;
	}

	static function allocateType(code:HlCode, builder:HlTypeBuilder, definition:HlTypeDef):RawPtr<runtime.hashlink.HlType> {
		return switch definition {
			case Simple(kind):
				builder.primitive(runtimeKind(kind));
			case Parameterized(kind, _):
				builder.parameterizedType(runtimeKind(kind), RawPtr.nullPtr());
			case Abstract(name):
				builder.abstractType(builder.utf16Name(code.strings[name]));
			case Function(_, _):
				builder.functionTypeSkeleton(HlTypeKind.Function);
			case Method(_, _):
				builder.functionTypeSkeleton(HlTypeKind.Method);
			case Object(_, _, _, _, _, _):
				builder.objectTypeSkeleton(HlTypeKind.Object);
			case Structure(_, _, _, _, _):
				builder.objectTypeSkeleton(HlTypeKind.Struct);
			case Virtual(_):
				builder.virtualTypeSkeleton();
			case Enum(_, _, _):
				builder.enumTypeSkeleton();
		};
	}

	static function allocatePatchType(module:HlModule, patch:HlPatch, builder:HlTypeBuilder, definition:HlTypeDef):RawPtr<runtime.hashlink.HlType> {
		return switch definition {
			case Simple(kind):
				if (kind == HlType.Ref || kind == HlType.Null || kind == HlType.Packed || kind == HlType.Obj || kind == HlType.Virtual
					|| kind == HlType.Enum || kind == HlType.Method || kind == HlType.Struct)
					throw 'Unsupported appended HashLink type kind $kind';
				builder.primitive(runtimeKind(kind));
			case Parameterized(kind, _):
				builder.parameterizedType(patchKind(kind), RawPtr.nullPtr());
			case Abstract(name):
				builder.abstractType(builder.utf16Name(patchString(module, patch, name)));
			case Function(_, _):
				builder.functionTypeSkeleton(HlTypeKind.Function);
			case Method(_, _), Object(_, _, _, _, _, _), Structure(_, _, _, _, _), Virtual(_), Enum(_, _, _):
				throw "Unsupported appended HashLink type definition";
		};
	}

	static function definePatchType(builder:HlTypeBuilder, type:RawPtr<runtime.hashlink.HlType>, definition:HlTypeDef,
			allTypes:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		switch definition {
			case Simple(_), Abstract(_):
			case Parameterized(_, parameter):
				checkPatchTypeIndex(parameter, allTypes.length);
				type.ref.data.ref.typeParam = allTypes[parameter];
			case Function(arguments, result):
				for (argument in arguments)
					checkPatchTypeIndex(argument, allTypes.length);
				checkPatchTypeIndex(result, allTypes.length);
				builder.defineFunctionType(type, typePointers(allTypes, arguments), allTypes[result]);
			case Method(_, _), Object(_, _, _, _, _, _), Structure(_, _, _, _, _), Virtual(_), Enum(_, _, _):
				throw "Unsupported appended HashLink type definition";
		}
	}

	static function writePatchFunction(destination:RawPtr<runtime.hashlink.HlFunction>, generation:HlMetadataGeneration, patch:HlPatch,
			patchFunction:HlPatchFunction, typeCount:Int, identity:HlRuntimeManifest):Void {
		checkPatchTypeIndex(patchFunction.type, typeCount);
		var registers:RawPtr<RawPtr<runtime.hashlink.HlType>> = patchFunction.registers.length == 0 ? RawPtr.nullPtr() : generation.arena.allocTypePointerArray(patchFunction.registers.length);
		for (index in 0...patchFunction.registers.length) {
			checkPatchTypeIndex(patchFunction.registers[index], typeCount);
			registers.offset(index).store(generation.type(patchFunction.registers[index]));
		}
		var ops:RawPtr<runtime.hashlink.HlOpcode> = patchFunction.instructions.length == 0 ? RawPtr.nullPtr() : generation.arena.allocOpcodeArray(patchFunction.instructions.length);
		for (index in 0...patchFunction.instructions.length)
			writePatchOpcode(ops.offset(index), generation, resolvedPatchInstruction(patchFunction, index, identity));
		var debug:RawPtr<Int32> = patchFunction.debug.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(patchFunction.debug.length * 2);
		for (index in 0...patchFunction.debug.length) {
			var location = patchFunction.debug[index];
			if (location.file < 0 || location.file >= patch.debugFiles.length)
				throw 'HashLink patch function ${patchFunction.functionIndex} has an invalid debug file index';
			debug.offset(index * 2).store(cast generation.debugFileIndex(patch.debugFiles[location.file]));
			debug.offset(index * 2 + 1).store(cast location.line);
		}
		destination.ref.findex = cast patchFunction.slot;
		destination.ref.nregs = cast patchFunction.registers.length;
		destination.ref.nops = cast patchFunction.instructions.length;
		destination.ref.reference = cast 0;
		destination.ref.nassigns = cast 0;
		destination.ref.type = generation.type(patchFunction.type);
		destination.ref.regs = registers;
		destination.ref.ops = ops;
		destination.ref.debug = debug;
		destination.ref.assigns = RawPtr.nullPtr();
		destination.ref.object = RawPtr.nullPtr();
		destination.ref.field.ref.name = RawPtr.nullPtr();
	}

	static function resolvedPatchInstruction(patchFunction:HlPatchFunction, index:Int, identity:HlRuntimeManifest):HlPatchInstruction {
		var source = patchFunction.instructions[index],
			resolved:Null<HlPatchInstruction> = null;
		for (relocation in patchFunction.relocations)
			if (relocation.instruction == index) {
				if (source.operands.length < 2)
					throw 'HashLink patch relocation for function ${patchFunction.functionIndex} has no target operand';
				var target = identitySlot(identity, relocation.stableId);
				if (target < 0)
					throw 'HashLink patch relocation references unknown function identity ${relocation.stableId}';
				var operands = source.operands.copy();
				operands[1] = target;
				resolved = new HlPatchInstruction(source.opcode, operands);
			}
		return resolved == null ? source : resolved;
	}

	static function identitySlot(identity:HlRuntimeManifest, stableId:Int):Int {
		for (entry in identity.entries)
			if (entry.stableId == stableId)
				return entry.functionIndex;
		return -1;
	}

	static function writePatchOpcode(destination:RawPtr<runtime.hashlink.HlOpcode>, generation:HlMetadataGeneration,
			instruction:compiler.hl.patch.HlPatch.HlPatchInstruction):Void {
		var operands = instruction.operands;
		destination.ref.op = cast instruction.opcode;
		destination.ref.p1 = cast operand(operands, 0);
		destination.ref.p2 = cast operand(operands, 1);
		destination.ref.p3 = cast operand(operands, 2);
		destination.ref.extra = RawPtr.nullPtr();
		var opcode:HlOpcode = cast instruction.opcode;
		if (operands.length == 4 && !patchOpcodeHasArrayExtra(opcode))
			destination.ref.extra = immediatePointer(operands[3]);
		var extraCount = patchOpcodeArrayExtraCount(opcode, operands.length);
		if (extraCount > 0) {
			var extra = generation.arena.allocInt32Array(extraCount);
			for (index in 0...extraCount)
				extra.offset(index).store(cast operands[index + 3]);
			destination.ref.extra = extra;
		}
	}

	static function patchOpcodeHasArrayExtra(opcode:Int):Bool
		return patchOpcodeArrayExtraCount(opcode, 4) > 0;

	static function patchOpcodeArrayExtraCount(opcode:Int, operandCount:Int):Int {
		var typedOpcode:HlOpcode = cast opcode;
		return switch typedOpcode {
			case HlOpcode.Call3: 2;
			case HlOpcode.Call4: 3;
			case HlOpcode.CallN | HlOpcode.CallMethod | HlOpcode.CallThis | HlOpcode.CallClosure | HlOpcode.MakeEnum:
				operandCount > 3 ? operandCount - 3 : 0;
			case _: 0;
		};
	}

	static function patchKind(kind:HlType):HlTypeKind {
		return switch kind {
			case HlType.Ref: HlTypeKind.Reference;
			case HlType.Null: HlTypeKind.Nullable;
			case _: throw 'Unsupported parameterized appended HashLink type kind $kind';
		};
	}

	static function patchString(module:HlModule, patch:HlPatch, index:Int):String {
		if (index < 0)
			throw 'Invalid appended HashLink string index $index';
		if (index < patch.baseStrings)
			return module.code.strings[index];
		var appended = index - patch.baseStrings;
		if (appended < 0 || appended >= patch.strings.length)
			throw 'Invalid appended HashLink string index $index';
		return patch.strings[appended];
	}

	static function checkPatchTypeIndex(index:Int, count:Int):Void
		if (index < 0 || index >= count)
			throw 'Invalid appended HashLink type reference $index';

	static function defineTypes(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>,
			module:RawPtr<runtime.hashlink.HlModuleContext>, globals:RawPtr<RawPtr<UInt8>>):Void {
		for (index in 0...code.types.length)
			switch code.types[index] {
				case Simple(_):
				case Parameterized(kind, parameter):
					types[index].ref.data.ref.typeParam = types[parameter];
				case Abstract(_):
				case Function(arguments, result), Method(arguments, result):
					generation.builder.defineFunctionType(types[index], typePointers(types, arguments), types[result]);
				case Object(name, base, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, base, global, fields, methods, bindings, module, globals, false, types);
				case Structure(name, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, -1, global, fields, methods, bindings, module, globals, true, types);
				case Virtual(fields):
					generation.builder.defineVirtualType(types[index], objectFields(code, generation.builder, fields, types), 0, [for (_ in fields) 0],
						RawPtr.nullPtr());
				case Enum(name, global, constructors):
					generation.builder.defineEnumType(types[index], generation.builder.utf16Name(code.strings[name]),
						enumConstructors(code, generation, constructors, types), global == 0 ? RawPtr.nullPtr() : generation.globalIndex(global));
			}
	}

	static function defineObject(code:HlCode, generation:HlMetadataGeneration, type:RawPtr<runtime.hashlink.HlType>, name:Int, base:Int, global:Int,
			fields:Array<HlCode.HlObjectField>, methods:Array<HlCode.HlObjectMethod>, bindings:Array<Int>, module:RawPtr<runtime.hashlink.HlModuleContext>,
			globals:RawPtr<RawPtr<UInt8>>, structure:Bool, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		if (bindings.length % 2 != 0)
			throw 'HashLink object type $name has an incomplete binding pair';
		var objectBindings:Array<runtime.hashlink.HlTypeBuilder.HlObjectBindingSpec> = [];
		for (index in 0...Std.int(bindings.length / 2)) {
			var fieldIndex = bindings[index * 2],
				functionIndex = bindings[index * 2 + 1];
			if (fieldIndex < 0 || fieldIndex >= fields.length || functionIndex < 0)
				throw 'HashLink object type $name has an invalid binding ($fieldIndex, $functionIndex)';
			objectBindings.push({fieldIndex: fieldIndex, functionIndex: functionIndex});
		}
		var objectType = structure ? HlTypeKind.Struct : HlTypeKind.Object;
		var actualType:HlTypeKind = cast type.ref.kind;
		if (actualType != objectType)
			throw "HashLink object definition kind does not match its type skeleton";
		generation.builder.defineObjectType(type, generation.builder.utf16Name(code.strings[name]), base < 0 ? RawPtr.nullPtr() : types[base],
			objectFields(code, generation.builder, fields, types), objectPrototypes(code, generation.builder, methods), objectBindings,
			global == 0 ? RawPtr.nullPtr() : generation.globalIndex(global), module, RawPtr.nullPtr());
	}

	static function objectFields(code:HlCode, builder:HlTypeBuilder, fields:Array<HlCode.HlObjectField>,
			types:Array<RawPtr<runtime.hashlink.HlType>>):Array<runtime.hashlink.HlTypeBuilder.HlObjectFieldSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlObjectFieldSpec> = [];
		for (field in fields) {
			var fieldName = code.strings[field.name];
			result.push({name: builder.utf16Name(fieldName), type: types[field.type], hashedName: HlTypeBuilder.hashUtf16(fieldName)});
		}
		return result;
	}

	static function objectPrototypes(code:HlCode, builder:HlTypeBuilder,
			methods:Array<HlCode.HlObjectMethod>):Array<runtime.hashlink.HlTypeBuilder.HlObjectProtoSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlObjectProtoSpec> = [];
		for (method in methods) {
			var methodName = code.strings[method.name];
			result.push({
				name: builder.utf16Name(methodName),
				findex: method.functionIndex,
				pindex: method.prototype,
				hashedName: HlTypeBuilder.hashUtf16(methodName)
			});
		}
		return result;
	}

	static function enumConstructors(code:HlCode, generation:HlMetadataGeneration, constructors:Array<compiler.hl.HlCode.HlEnumConstructor>,
			types:Array<RawPtr<runtime.hashlink.HlType>>):Array<runtime.hashlink.HlTypeBuilder.HlEnumConstructSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlEnumConstructSpec> = [];
		for (constructor in constructors) {
			var parameters = typePointers(types, constructor.params);
			result.push({
				name: generation.builder.utf16Name(code.strings[constructor.name]),
				parameters: parameters,
				size: 0,
				hasPtr: false,
				offsets: [for (_ in parameters) 0]
			});
		}
		return result;
	}

	static function addFunctionDescriptors(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		for (fn in code.functions) {
			var registers:RawPtr<RawPtr<runtime.hashlink.HlType>> = fn.registers.length == 0 ? RawPtr.nullPtr() : generation.arena.allocTypePointerArray(fn.registers.length);
			for (index in 0...fn.registers.length)
				registers.offset(index).store(types[fn.registers[index]]);
			var encoded = HlWriter.lower(fn),
				ops:RawPtr<runtime.hashlink.HlOpcode> = encoded.length == 0 ? RawPtr.nullPtr() : generation.arena.allocOpcodeArray(encoded.length);
			for (index in 0...encoded.length)
				writeOpcode(ops.offset(index), encoded[index], generation);
			var debug:RawPtr<Int32> = encoded.length == 0
				|| generation.debugFileCountOf() == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(encoded.length * 2);
			if (!debug.isNull())
				for (index in 0...encoded.length) {
					var location = debugLocation(fn, index);
					debug.offset(index * 2).store(cast generation.debugFileIndex(location.path));
					debug.offset(index * 2 + 1).store(cast location.line);
				}
			var assigns:RawPtr<Int32> = fn.debugAssignments.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(fn.debugAssignments.length * 3);
			for (index in 0...fn.debugAssignments.length) {
				var assignment = fn.debugAssignments[index];
				if (assignment.name < 0 || assignment.name >= code.strings.length)
					throw 'HashLink function ${fn.functionIndex} has an invalid debug assignment name';
				assigns.offset(index * 3).store(cast assignment.name);
				assigns.offset(index * 3 + 1).store(cast assignment.position);
				assigns.offset(index * 3 + 2).store(cast assignment.scopeEnd);
			}
			generation.addFunctionDescriptor({
				findex: fn.functionIndex,
				nregs: fn.registers.length,
				nops: encoded.length,
				reference: 0,
				nassigns: fn.debugAssignments.length,
				type: types[fn.type],
				regs: registers,
				ops: ops,
				debug: debug,
				assigns: assigns,
				object: RawPtr.nullPtr(),
				fieldName: RawPtr.nullPtr(),
				fieldReference: RawPtr.nullPtr()
			});
		}
	}

	static function defineFunctionIdentities(module:HlModule, generation:HlMetadataGeneration):Void {
		var stableIds:Array<Int> = [], names:Array<String> = [];
		for (fn in module.code.functions) {
			var identity = module.identityAt(fn.functionIndex);
			stableIds.push(module.stableIdAt(fn.functionIndex));
			names.push(identity == null ? "" : identity.qualifiedName);
		}
		generation.defineFunctionIdentities(stableIds, names);
	}

	static function debugLocation(fn:HlFunction, index:Int):HlDebugLocation {
		if (fn.debugLocations.length == 0)
			return {
				path: "<generated>",
				line: 1,
				column: 1,
				endLine: 1,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			};
		return fn.debugLocations[index];
	}

	static function debugFilePaths(code:HlCode):Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		var hasDebug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length != 0)
				hasDebug = true;
		if (!hasDebug)
			return result;
		for (fn in code.functions) {
			if (fn.debugLocations.length == 0)
				addDebugFile(result, seen, "<generated>");
			else
				for (location in fn.debugLocations)
					addDebugFile(result, seen, location.path);
		}
		return result;
	}

	static function addDebugFile(result:Array<String>, seen:Map<String, Bool>, path:String):Void {
		if (!seen.exists(path)) {
			seen.set(path, true);
			result.push(path);
		}
	}

	static function writeOpcode(destination:RawPtr<runtime.hashlink.HlOpcode>, encoded:HlEncodedInstruction, generation:HlMetadataGeneration):Void {
		var operands = encoded.operands;
		destination.ref.op = cast encoded.opcode;
		destination.ref.p1 = cast operand(operands, 0);
		destination.ref.p2 = cast operand(operands, 1);
		destination.ref.p3 = cast operand(operands, 2);
		destination.ref.extra = RawPtr.nullPtr();
		switch encoded.opcode {
			case HlOpcode.Call2 | HlOpcode.EnumField:
				// HashLink stores the fourth fixed operand in the pointer field as an
				// immediate register/field index, not as an address.
				destination.ref.extra = immediatePointer(operands[3]);
			case HlOpcode.Call3:
				destination.ref.extra = copyOperands(generation, operands, 3, 2);
			case HlOpcode.Call4:
				destination.ref.extra = copyOperands(generation, operands, 3, 3);
			case HlOpcode.CallN | HlOpcode.CallMethod | HlOpcode.CallThis | HlOpcode.CallClosure | HlOpcode.MakeEnum:
				destination.ref.extra = copyOperands(generation, operands, 3, operands[2]);
			case HlOpcode.Switch:
				destination.ref.p3 = cast operands[operands[1] + 2];
				destination.ref.extra = copyOperands(generation, operands, 2, operands[1]);
			case _:
		}
	}

	static function operand(operands:Array<Int>, index:Int):Int
		return index < operands.length ? operands[index] : 0;

	static function copyOperands(generation:HlMetadataGeneration, operands:Array<Int>, start:Int, count:Int):RawPtr<Int32> {
		if (count == 0)
			return RawPtr.nullPtr();
		var result = generation.arena.allocInt32Array(count);
		for (index in 0...count)
			result.offset(index).store(cast operands[start + index]);
		return result;
	}

	static function immediatePointer(value:Int):RawPtr<Int32> {
		var pointer:RawPtr<Int32> = RawPtr.nullPtr();
		return pointer.byteOffset(value);
	}

	static function addNativeDescriptors(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		for (native in code.natives)
			generation.addNativeDescriptor({
				library: generation.stringPointer(native.library),
				name: generation.stringPointer(native.name),
				type: types[native.type],
				findex: native.functionIndex
			});
	}

	static function addConstants(code:HlCode, generation:HlMetadataGeneration):Void {
		for (constant in code.constants) {
			var fields:RawPtr<Int32> = constant.fields.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(constant.fields.length);
			for (index in 0...constant.fields.length)
				fields.offset(index).store(cast constant.fields[index]);
			generation.addConstant({
				global: constant.global,
				nfields: constant.fields.length,
				fields: fields
			});
		}
	}

	static function dispatchSlotCount(code:HlCode):Int {
		var maximum = -1;
		for (native in code.natives)
			if (native.functionIndex > maximum)
				maximum = native.functionIndex;
		for (fn in code.functions)
			if (fn.functionIndex > maximum)
				maximum = fn.functionIndex;
		return maximum + 1;
	}

	static function dispatchPointers(count:Int, supplied:Null<Array<RawPtr<UInt8>>>):Array<RawPtr<UInt8>> {
		if (supplied != null && supplied.length != count)
			throw 'HashLink function pointer table has ${supplied.length} entries, expected $count';
		var result:Array<RawPtr<UInt8>> = [];
		for (index in 0...count)
			result.push(supplied == null ? RawPtr.nullPtr() : supplied[index]);
		return result;
	}

	static function dispatchTypes(code:HlCode, types:Array<RawPtr<runtime.hashlink.HlType>>, count:Int):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (_ in 0...count)
			result.push(RawPtr.nullPtr());
		for (native in code.natives)
			result[native.functionIndex] = types[native.type];
		for (fn in code.functions)
			result[fn.functionIndex] = types[fn.type];
		return result;
	}

	static function typePointers(types:Array<RawPtr<runtime.hashlink.HlType>>, indices:Array<Int>):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (index in indices)
			result.push(types[index]);
		return result;
	}

	static function runtimeKind(kind:HlType):HlTypeKind {
		return switch kind {
			case HlType.Void: HlTypeKind.VoidType;
			case HlType.Ui8: HlTypeKind.UInt8Type;
			case HlType.Ui16: HlTypeKind.UInt16Type;
			case HlType.I32: HlTypeKind.Int32Type;
			case HlType.I64: HlTypeKind.Int64Type;
			case HlType.F32: HlTypeKind.Float32Type;
			case HlType.F64: HlTypeKind.Float64Type;
			case HlType.Bool: HlTypeKind.BoolType;
			case HlType.Bytes: HlTypeKind.BytesType;
			case HlType.Dyn: HlTypeKind.DynamicType;
			case HlType.Fun: HlTypeKind.Function;
			case HlType.Obj: HlTypeKind.Object;
			case HlType.Array: HlTypeKind.Array;
			case HlType.Type: HlTypeKind.Type;
			case HlType.Ref: HlTypeKind.Reference;
			case HlType.Virtual: HlTypeKind.Virtual;
			case HlType.DynObj: HlTypeKind.DynamicObject;
			case HlType.Abstract: HlTypeKind.Abstract;
			case HlType.Enum: HlTypeKind.Enum;
			case HlType.Null: HlTypeKind.Nullable;
			case HlType.Method: HlTypeKind.Method;
			case HlType.Struct: HlTypeKind.Struct;
			case HlType.Packed: HlTypeKind.Packed;
			case HlType.Guid: HlTypeKind.Guid;
			case _: throw 'Unknown HashLink type kind $kind';
		};
	}

	static inline function positive(value:Int):Int
		return value <= 0 ? 1 : value;
}
