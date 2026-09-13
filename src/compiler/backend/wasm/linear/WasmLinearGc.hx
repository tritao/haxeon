package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmBackend;

class WasmLinearGc {
	public static function build(context:WasmLinearContext):Void {
		context.markFunction = addGcMark(context);
		context.traceFunction = addGcTrace(context);
		context.collectorFunction = addGcCollector(context);
	}

	public static function wrapRuntimeFunctions(context:WasmLinearContext, count:Int):Void {
		var module = context.module;
		for (index in 0...count) {
			var fn = module.functions[index];
			if (fn.name == "__haxeon_gc_mark" || fn.name == "__haxeon_gc_trace" || fn.name == "__haxeon_gc_collect")
				continue;
			module.setFunction(module.imports.length + index, wrapRuntimeFunction(context, fn));
		}
	}

	static function wrapRuntimeFunction(context:WasmLinearContext, fn:WasmFunction):WasmFunction {
		var rootTop = context.rootTop,
			rootFrameTop = context.rootFrameTop,
			rootLimit = context.rootLimit,
			exceptionTag = context.exceptionTag;
		var rootSlots:Array<Int> = [];
		for (index in 0...fn.type.parameters.length)
			if (fn.type.parameters[index] == I32)
				rootSlots.push(index);
		for (index in 0...fn.locals.length)
			if (fn.locals[index].type == I32)
				rootSlots.push(fn.type.parameters.length + index);
		if (rootSlots.length == 0)
			return fn;
		var frame = fn.type.parameters.length + fn.locals.length,
			locals = fn.locals.copy(),
			exceptionLocal = frame + 1;
		locals.push({type: I32});
		if (exceptionTag != null)
			locals.push({type: I32});
		var frameSize = WasmBackend.align(12 + rootSlots.length * 4, 8),
			body:Array<WasmInstruction> = [
				GlobalGet(rootTop),
				I32Const(frameSize),
				I32Add,
				I32Const(rootLimit),
				I32LeS,
				I32Eqz,
				If(null),
				Unreachable,
				End,
				GlobalGet(rootTop),
				LocalTee(frame),
				GlobalGet(rootTop),
				I32Store(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET),
				LocalGet(frame),
				GlobalGet(rootFrameTop),
				I32Store(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
				LocalGet(frame),
				I32Const(rootSlots.length),
				I32Store(WasmLayout.ROOT_COUNT_OFFSET),
				LocalGet(frame),
				I32Const(frameSize),
				I32Add,
				GlobalSet(rootTop),
				LocalGet(frame),
				GlobalSet(rootFrameTop)
			];
		for (instruction in fn.body) {
			if (isRuntimeCall(instruction))
				appendRuntimeRootSnapshot(body, frame, rootSlots);
			if (instruction == Return) {
				emitRuntimeRootFrameRestore(body, frame, context);
			}
			body.push(instruction);
			if (isRuntimeLocalWrite(instruction))
				appendRuntimeRootSnapshot(body, frame, rootSlots);
		}
		// Runtime helpers often use Wasm's implicit void return instead of an
		// explicit Return instruction. Balance their shadow-root frame on that
		// normal fallthrough path as well; otherwise each helper call permanently
		// consumes root-stack space until a later call traps at rootLimit.
		if (fn.body.length == 0 || fn.body[fn.body.length - 1] != Return)
			emitRuntimeRootFrameRestore(body, frame, context);
		if (exceptionTag != null) {
			var protectedBody:Array<WasmInstruction> = [Try(null)];
			protectedBody = protectedBody.concat(body);
			protectedBody.push(Catch(exceptionTag));
			protectedBody.push(LocalSet(exceptionLocal));
			emitRuntimeRootFrameRestore(protectedBody, frame, context);
			protectedBody = protectedBody.concat([LocalGet(exceptionLocal), Throw(exceptionTag), End]);
			// Result-bearing runtime helpers terminate with explicit Return
			// instructions. Keep the unreachable marker for validation of those
			// result paths; void helpers may complete via implicit fallthrough.
			if (fn.type.results.length != 0)
				protectedBody.push(Unreachable);
			body = protectedBody;
		}
		return new WasmFunction(fn.name, fn.type, locals, body);
	}

	static function emitRuntimeRootFrameRestore(body:Array<WasmInstruction>, frame:Int, context:WasmLinearContext):Void {
		var rootTop = context.rootTop, rootFrameTop = context.rootFrameTop;
		body.push(LocalGet(frame));
		body.push(I32Load(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET));
		body.push(GlobalSet(rootTop));
		body.push(LocalGet(frame));
		body.push(I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
		body.push(GlobalSet(rootFrameTop));
	}

	static function isRuntimeCall(instruction:WasmInstruction):Bool
		return switch instruction {
			case Call(_): true;
			default: false;
		};

	static function isRuntimeLocalWrite(instruction:WasmInstruction):Bool
		return switch instruction {
			case LocalSet(_), LocalTee(_): true;
			default: false;
		};

	static function appendRuntimeRootSnapshot(body:Array<WasmInstruction>, frame:Int, slots:Array<Int>):Void {
		for (index in 0...slots.length) {
			body.push(LocalGet(frame));
			body.push(I32Const(WasmLayout.ROOT_VALUES_OFFSET + index * 4));
			body.push(I32Add);
			body.push(LocalGet(slots[index]));
			body.push(I32Store(0));
		}
	}

	static function appendRuntime(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function addGcMark(context:WasmLinearContext):Int {
		var module = context.module,
			heapStart = context.heapStart,
			heapTop = context.heapTop,
			markStackTop = context.markStackTop;
		var type:WasmFunctionType = {parameters: [I32], results: []},
			index = module.addFunction(new WasmFunction("__haxeon_gc_mark", type));
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(heapStart + WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			LocalSet(1),
			GlobalGet(heapTop),
			LocalGet(1),
			I32LeS,
			If(null),
			Return,
			End,
			LocalGet(0),
			GlobalGet(heapTop),
			I32LeS,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			LocalSet(2),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MAGIC_MASK),
			I32And,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Eq,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_ALLOCATED),
			I32And,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			LocalGet(0),
			I32Eq,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Return,
			End,
			LocalGet(3),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(3),
			GlobalGet(heapTop),
			LocalGet(1),
			I32Sub,
			I32LeS,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32And,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32Or,
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_SCAN_REFERENCES),
			I32And,
			I32Eqz,
			If(null),
			Return,
			End,
			GlobalGet(markStackTop),
			I32Const(4),
			I32Add,
			MemorySize,
			I32Const(65536),
			I32Mul,
			I32LeS,
			I32Eqz,
			If(null),
			I32Const(1),
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			GlobalGet(markStackTop),
			LocalGet(1),
			I32Store(0),
			GlobalGet(markStackTop),
			I32Const(4),
			I32Add,
			GlobalSet(markStackTop),
			Return
		];
		module.setFunction(index, new WasmFunction("__haxeon_gc_mark", type, [for (_ in 0...3) {type: I32}], body));
		return index;
	}

	static function addGcTrace(context:WasmLinearContext):Int {
		var module = context.module,
			program = context.program,
			layout = context.layout,
			mark = context.markFunction;
		var type:WasmFunctionType = {parameters: [I32], results: []},
			index = module.addFunction(new WasmFunction("__haxeon_gc_trace", type));
		var body:Array<WasmInstruction> = [LocalGet(0), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, LocalSet(1)];
		var mapNames:Array<String> = [];
		for (native in program.natives) {
			var parts = WasmBackend.mapNativeParts(native.name);
			if (parts != null && parts.operation == "alloc" && mapNames.indexOf(parts.mapName) < 0)
				mapNames.push(parts.mapName);
		}
		mapNames.sort(Reflect.compare);

		// Array and map backing blocks keep their owner in the auxiliary block
		// link while allocated. Trace only the active logical entries.
		body = body.concat([
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET),
			LocalTee(5),
			I32Eqz,
			If(null),
			Else
		]);
		body.push(LocalGet(5));
		body.push(I32Load(0));
		body.push(I32Const(WasmBackend.typeId(Array(Dyn))));
		body.push(I32Eq);
		body.push(If(null));
		appendGcArrayContents(body, mark);
		body.push(Return);
		body.push(End);
		for (mapName in mapNames) {
			body.push(LocalGet(5));
			body.push(I32Load(0));
			body.push(I32Const(WasmBackend.typeId(Abstract(mapName))));
			body.push(I32Eq);
			body.push(If(null));
			appendGcMapContents(body, mark, mapName);
			body.push(Return);
			body.push(End);
		}
		appendGcConservativeTrace(body, mark);
		body.push(Return);
		body.push(End);

		// Primitive boxes and byte payloads are leaves. Other known layouts are
		// traced from their declared reference fields, not by scanning scalars.
		var leafTypes:Array<IrType> = [Bytes, I32, Bool, I64, F64];
		for (leaf in leafTypes)
			appendGcTraceCase(body, WasmBackend.typeId(leaf), []);
		for (object in program.objects) {
			var references = [];
			for (field in layout.object(object.name).fields)
				if (WasmTarget.isReference(field.type))
					references = references.concat([LocalGet(0), I32Load(field.offset), Call(mark)]);
			appendGcTraceCase(body, WasmBackend.typeId(Obj(object.name)), references);
		}
		for (enumDecl in program.enums) {
			var enumLayout = layout.enumType(enumDecl.name);
			body = body.concat([
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(Enum(enumDecl.name))),
				I32Eq,
				If(null),
				LocalGet(0),
				I32Load(WasmLayout.HEADER_SIZE),
				LocalSet(5)
			]);
			for (caseIndex in 0...enumLayout.cases.length) {
				var references:Array<WasmInstruction> = [];
				for (fieldIndex in 0...enumLayout.cases[caseIndex].length) {
					var field = layout.enumField(enumDecl.name, caseIndex, fieldIndex);
					if (WasmTarget.isReference(field.type))
						references = references.concat([LocalGet(0), I32Load(field.offset), Call(mark)]);
				}
				body = body.concat([LocalGet(5), I32Const(caseIndex), I32Eq, If(null)]);
				body = body.concat(references);
				body = body.concat([Return, End]);
			}
			body = body.concat([Return, End]);
		}
		for (mapName in mapNames)
			appendGcTraceCase(body, WasmBackend.typeId(Abstract(mapName)), [LocalGet(0), I32Load(WasmLayout.MAP_ENTRIES_OFFSET), Call(mark)]);
		appendGcTraceCase(body, WasmBackend.typeId(Array(Dyn)), [LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), Call(mark)]);
		appendGcTraceCase(body, WasmBackend.typeId(Abstract("realtime_iterator")), [LocalGet(0), I32Load(WasmLayout.ITERATOR_ARRAY_OFFSET), Call(mark)]);
		appendGcTraceCase(body, WasmLayout.CLOSURE_TYPE_ID, [LocalGet(0), I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET), Call(mark)]);
		appendGcConservativeTrace(body, mark);
		body.push(Return);
		module.setFunction(index, new WasmFunction("__haxeon_gc_trace", type, [for (_ in 0...5) {type: I32}], body));
		return index;
	}

	static function appendGcTraceCase(body:Array<WasmInstruction>, id:Int, trace:Array<WasmInstruction>):Void {
		body.push(LocalGet(0));
		body.push(I32Load(0));
		body.push(I32Const(id));
		body.push(I32Eq);
		body.push(If(null));
		for (instruction in trace)
			body.push(instruction);
		body.push(Return);
		body.push(End);
	}

	static function appendGcArrayContents(body:Array<WasmInstruction>, mark:Int):Void {
		WasmLinearRuntime.append(body, [
			LocalGet(5),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			LocalGet(4),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(mark),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
	}

	static function appendGcMapContents(body:Array<WasmInstruction>, mark:Int, mapName:String):Void {
		var keyType = WasmLinearRuntime.mapKeyType(mapName),
			valueType = WasmLinearRuntime.mapValueType(mapName),
			entrySize = WasmLinearRuntime.mapEntrySize(valueType),
			valueOffset = WasmLinearRuntime.mapValueOffset(valueType);
		WasmLinearRuntime.append(body, [
			LocalGet(5),
			I32Load(WasmLayout.MAP_COUNT_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null)
		]);
		if (WasmTarget.isReference(keyType))
			WasmLinearRuntime.append(body, [
				LocalGet(0),
				LocalGet(4),
				I32Const(entrySize),
				I32Mul,
				I32Add,
				I32Load(0),
				Call(mark)
			]);
		if (WasmTarget.isReference(valueType))
			WasmLinearRuntime.append(body, [
				LocalGet(0),
				LocalGet(4),
				I32Const(entrySize),
				I32Mul,
				I32Add,
				I32Load(valueOffset),
				Call(mark)
			]);
		WasmLinearRuntime.append(body, [LocalGet(4), I32Const(1), I32Add, LocalSet(4), Br(1), Else, Br(2), End, End, End]);
	}

	static function appendGcConservativeTrace(body:Array<WasmInstruction>, mark:Int):Void {
		WasmLinearRuntime.append(body, [
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			LocalGet(4),
			I32Add,
			I32Load(0),
			Call(mark),
			LocalGet(4),
			I32Const(4),
			I32Add,
			LocalSet(4),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
	}

	static function addGcCollector(context:WasmLinearContext):Int {
		var module = context.module,
			heapStart = context.heapStart,
			heapTop = context.heapTop,
			rootFrameTop = context.rootFrameTop,
			freeHead = context.freeHead,
			mark = context.markFunction,
			trace = context.traceFunction,
			markStackTop = context.markStackTop,
			rootGlobals = context.rootGlobals,
			collectionCount = context.collectionCount;
		var type:WasmFunctionType = {parameters: [], results: []},
			body:Array<WasmInstruction> = [];
		body = body.concat([GlobalGet(heapTop), GlobalSet(markStackTop)]);
		if (collectionCount >= 0)
			body = body.concat([GlobalGet(collectionCount), I32Const(1), I32Add, GlobalSet(collectionCount)]);
		body = body.concat([
			GlobalGet(rootFrameTop),
			LocalSet(0),
			Block(null),
			Loop(null),
			LocalGet(0),
			I32Eqz,
			If(null),
			Br(2),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ROOT_COUNT_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalSet(2),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Const(WasmLayout.ROOT_VALUES_OFFSET),
			I32Add,
			LocalGet(2),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(mark),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
			LocalSet(0),
			Br(1),
			End,
			End,
			End,
		]);
		for (global in rootGlobals) {
			body.push(GlobalGet(global));
			body.push(Call(mark));
		}
		body = body.concat([
			Block(null),
			Loop(null),
			GlobalGet(markStackTop),
			GlobalGet(heapTop),
			I32LeS,
			BrIf(1),
			GlobalGet(markStackTop),
			I32Const(4),
			I32Sub,
			GlobalSet(markStackTop),
			GlobalGet(markStackTop),
			I32Load(0),
			LocalSet(8),
			GlobalGet(markStackTop),
			I32Const(0),
			I32Store(0),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			Call(trace),
			Br(0),
			End,
			End
		]);
		var appendFreeRun:Array<WasmInstruction> = [
			LocalGet(7),
			I32Eqz,
			If(null),
			LocalGet(3),
			LocalSet(6),
			End,
			LocalGet(7),
			LocalGet(4),
			I32Add,
			LocalSet(7)
		];
		var flushFreeRun:Array<WasmInstruction> = [
			LocalGet(7),
			I32Eqz,
			I32Eqz,
			If(null),
			LocalGet(6),
			LocalGet(7),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Store(0),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			GlobalGet(freeHead),
			I32Store(0),
			LocalGet(6),
			GlobalSet(freeHead),
			End
		];
		body = body.concat([
			I32Const(0),
			GlobalSet(freeHead),
			I32Const(heapStart),
			LocalSet(3),
			I32Const(0),
			LocalSet(6),
			I32Const(0),
			LocalSet(7),
			Block(null),
			Loop(null),
			LocalGet(3),
			GlobalGet(heapTop),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(4),
			LocalGet(4),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Unreachable,
			End,
			LocalGet(4),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(4),
			GlobalGet(heapTop),
			LocalGet(3),
			I32Sub,
			I32LeS,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_MAGIC_MASK),
			I32And,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Eq,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_ALLOCATED),
			I32And,
			If(null),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32And,
			If(null)
		]);
		body = body.concat(flushFreeRun);
		body = body.concat([
			I32Const(0),
			LocalSet(6),
			I32Const(0),
			LocalSet(7),
			LocalGet(3),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_CLEAR_MARKED_MASK),
			I32And,
			I32Store(0),
			Else
		]);
		body = body.concat(appendFreeRun);
		body = body.concat([End, Else]);
		body = body.concat(appendFreeRun);
		body = body.concat([
			End,
			LocalGet(3),
			LocalGet(4),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
		body = body.concat(flushFreeRun);
		body.push(Return);
		return module.addFunction(new WasmFunction("__haxeon_gc_collect", type, [for (_ in 0...9) {type: I32}], body));
	}

	public static function appendGcContainerOwner(body:Array<WasmInstruction>, backing:Int, owner:Int):Void {
		WasmLinearRuntime.append(body, [
			LocalGet(backing),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(owner),
			I32Store(0)
		]);
	}
}
