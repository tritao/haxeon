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
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmFunctionBuilder.WasmLocalRef;

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
			exceptionTag:Int = context.exceptionTag == null ? -1 : cast context.exceptionTag;
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
		if (exceptionTag >= 0)
			locals.push({type: I32});
		var frameSize = WasmModuleSupport.align(12 + rootSlots.length * 4, 8),
			guardBuilder = new WasmFunctionBuilder(fn.name, fn.type);
		guardBuilder.emit(GlobalGet(rootTop));
		guardBuilder.emit(I32Const(frameSize));
		guardBuilder.emit(I32Add);
		guardBuilder.emit(I32Const(rootLimit));
		guardBuilder.emit(I32LeS);
		guardBuilder.emit(I32Eqz);
		guardBuilder.if_(function(builder) builder.emit(Unreachable));
		guardBuilder.emit(GlobalGet(rootTop));
		guardBuilder.emit(LocalTee(frame));
		guardBuilder.emit(GlobalGet(rootTop));
		guardBuilder.emit(I32Store(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET));
		guardBuilder.emit(LocalGet(frame));
		guardBuilder.emit(GlobalGet(rootFrameTop));
		guardBuilder.emit(I32Store(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
		guardBuilder.emit(LocalGet(frame));
		guardBuilder.emit(I32Const(rootSlots.length));
		guardBuilder.emit(I32Store(WasmLayout.ROOT_COUNT_OFFSET));
		guardBuilder.emit(LocalGet(frame));
		guardBuilder.emit(I32Const(frameSize));
		guardBuilder.emit(I32Add);
		guardBuilder.emit(GlobalSet(rootTop));
		guardBuilder.emit(LocalGet(frame));
		guardBuilder.emit(GlobalSet(rootFrameTop));
		var body:Array<WasmInstruction> = guardBuilder.body.copy();
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
		if (exceptionTag >= 0) {
			var wrapper = new WasmFunctionBuilder(fn.name, fn.type);
			for (index in 0...locals.length)
				wrapper.local('local_$index', locals[index].type);
			wrapper.try_(function(builder) {
				builder.emitAll(body);
				builder.emit(Catch(exceptionTag));
				builder.localSet(new WasmLocalRef(exceptionLocal));
				emitRuntimeRootFrameRestore(builder.body, frame, context);
				builder.localGet(new WasmLocalRef(exceptionLocal));
				builder.emit(Throw(exceptionTag));
			});
			// Result-bearing runtime helpers terminate with explicit Return
			// instructions. Keep the unreachable marker for validation of those
			// result paths; void helpers may complete via implicit fallthrough.
			if (fn.type.results.length != 0)
				wrapper.emit(Unreachable);
			return wrapper.finish();
		}
		return WasmFunctionBuilder.fromRaw(fn.name, fn.type, locals, body);
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
			builder = new WasmFunctionBuilder("__haxeon_gc_mark", type),
			index = builder.register(module),
			value = builder.parameter("value", 0),
			header = builder.local("header", I32),
			flags = builder.local("flags", I32),
			size = builder.local("size", I32);

		builder.returnIfZero(value);

		builder.returnIfI32LtS(value, heapStart + WasmLayout.GC_BLOCK_HEADER_SIZE);

		builder.returnIfNotAligned(value, 8);

		builder.localGet(value);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.localSet(header);
		builder.globalGet(builder.global(heapTop));
		builder.localGet(header);
		builder.emit(I32LeS);
		builder.if_(function(builder) builder.return_());

		builder.localGet(value);
		builder.globalGet(builder.global(heapTop));
		builder.emit(I32LeS);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(header);
		builder.emit(I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET));
		builder.localSet(flags);
		builder.localGet(flags);
		builder.i32Const(WasmLayout.GC_BLOCK_MAGIC_MASK);
		builder.emit(I32And);
		builder.i32Const(WasmLayout.GC_BLOCK_MAGIC);
		builder.emit(I32Eq);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(flags);
		builder.i32Const(WasmLayout.GC_BLOCK_ALLOCATED);
		builder.emit(I32And);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(header);
		builder.emit(I32Load(WasmLayout.GC_BLOCK_OWNER_OFFSET));
		builder.localGet(value);
		builder.emit(I32Eq);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(header);
		builder.emit(I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET));
		builder.localSet(size);
		builder.localGet(size);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.return_());

		builder.localGet(size);
		builder.i32Const(7);
		builder.emit(I32And);
		builder.i32Eqz();
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(size);
		builder.globalGet(builder.global(heapTop));
		builder.localGet(header);
		builder.i32Sub();
		builder.emit(I32LeS);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.localGet(flags);
		builder.i32Const(WasmLayout.GC_BLOCK_MARKED);
		builder.emit(I32And);
		builder.if_(function(builder) builder.return_());

		builder.localGet(header);
		builder.i32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET);
		builder.i32Add();
		builder.localGet(flags);
		builder.i32Const(WasmLayout.GC_BLOCK_MARKED);
		builder.emit(I32Or);
		builder.emit(I32Store(0));

		builder.localGet(flags);
		builder.i32Const(WasmLayout.GC_BLOCK_SCAN_REFERENCES);
		builder.emit(I32And);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());

		builder.globalGet(builder.global(markStackTop));
		builder.i32Const(4);
		builder.i32Add();
		builder.emit(MemorySize);
		builder.i32Const(65536);
		builder.emit(I32Mul);
		builder.emit(I32LeS);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(1);
			builder.emit(MemoryGrow);
			builder.i32Const(-1);
			builder.emit(I32Eq);
			builder.if_(function(builder) builder.emit(Unreachable));
		});

		builder.globalGet(builder.global(markStackTop));
		builder.localGet(header);
		builder.emit(I32Store(0));
		builder.globalGet(builder.global(markStackTop));
		builder.i32Const(4);
		builder.i32Add();
		builder.globalSet(builder.global(markStackTop));
		builder.return_();

		module.setFunction(index, builder.finish());
		return index;
	}

	static function addGcTrace(context:WasmLinearContext):Int {
		var module = context.module,
			program = context.program,
			layout = context.layout,
			mark = context.markFunction;
		var type:WasmFunctionType = {parameters: [I32], results: []},
			builder = new WasmFunctionBuilder("__haxeon_gc_trace", type),
			index = builder.register(module),
			value = builder.parameter("value", 0),
			header = builder.local("header", I32),
			unused = builder.local("unused", I32),
			entryCount = builder.local("entryCount", I32),
			entryIndex = builder.local("entryIndex", I32),
			backingType = builder.local("backingType", I32);
		builder.localGet(value);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.localSet(header);
		var mapNames:Array<String> = [];
		for (native in program.natives) {
			var parts = WasmModuleSupport.mapNativeParts(native.name);
			if (parts != null && parts.operation == "alloc" && mapNames.indexOf(parts.mapName) < 0)
				mapNames.push(parts.mapName);
		}
		mapNames.sort(Reflect.compare);

		// Array and map backing blocks keep their owner in the auxiliary block
		// link while allocated. Trace only the active logical entries.
		builder.localGet(header);
		builder.emit(I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET));
		builder.localTee(backingType);
		builder.i32Eqz();
		builder.ifElse(function(_) {}, function(builder) {
			appendGcBackingTraceCase(builder, backingType, WasmModuleSupport.typeId(Array(Dyn)), function(builder) {
				appendGcArrayContents(builder, value, backingType, entryCount, entryIndex, mark);
			});
			for (mapName in mapNames)
				appendGcBackingTraceCase(builder, backingType, WasmModuleSupport.typeId(Abstract(mapName)), function(builder) {
					appendGcMapContents(builder, value, backingType, entryCount, entryIndex, mark, mapName);
				});
			appendGcConservativeTrace(builder, value, header, entryCount, entryIndex, mark);
			builder.return_();
		});

		// Primitive boxes are leaves. Byte views trace their backing owner; other
		// known layouts are traced from declared reference fields.
		var leafTypes:Array<IrType> = [I32, Bool, I64, F64];
		for (leaf in leafTypes)
			appendGcTraceCase(builder, value, WasmModuleSupport.typeId(leaf), function(_) {});
		appendGcTraceCase(builder, value, WasmModuleSupport.typeId(Bytes), function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_MARKER_OFFSET));
			builder.i32Const(WasmLayout.BYTES_VIEW_MAGIC);
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.localGet(value);
				builder.emit(I32Load(WasmLayout.BYTES_VIEW_OWNER_OFFSET));
				builder.call(builder.functionRef(mark));
				builder.localGet(value);
				builder.emit(I32Load(WasmLayout.BYTES_VIEW_ROOTS_OFFSET));
				builder.call(builder.functionRef(mark));
			});
		});
		for (object in program.objects)
			appendGcTraceCase(builder, value, WasmModuleSupport.typeId(Obj(object.name)), function(builder) {
				for (field in layout.object(object.name).fields)
					if (WasmTarget.isReference(field.type)) {
						builder.localGet(value);
						builder.emit(I32Load(field.offset));
						builder.call(builder.functionRef(mark));
					}
			});
		for (enumDecl in program.enums) {
			var enumLayout = layout.enumType(enumDecl.name);
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.i32Const(WasmModuleSupport.typeId(Enum(enumDecl.name)));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.localGet(value);
				builder.emit(I32Load(WasmLayout.HEADER_SIZE));
				builder.localSet(backingType);
				for (caseIndex in 0...enumLayout.cases.length) {
					builder.localGet(backingType);
					builder.i32Const(caseIndex);
					builder.emit(I32Eq);
					builder.if_(function(builder) {
						for (fieldIndex in 0...enumLayout.cases[caseIndex].length) {
							var field = layout.enumField(enumDecl.name, caseIndex, fieldIndex);
							if (WasmTarget.isReference(field.type)) {
								builder.localGet(value);
								builder.emit(I32Load(field.offset));
								builder.call(builder.functionRef(mark));
							}
						}
						builder.return_();
					});
				}
				builder.return_();
			});
		}
		for (mapName in mapNames)
			appendGcTraceCase(builder, value, WasmModuleSupport.typeId(Abstract(mapName)), function(builder) {
				builder.localGet(value);
				builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
				builder.call(builder.functionRef(mark));
			});
		appendGcTraceCase(builder, value, WasmModuleSupport.typeId(Array(Dyn)), function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.call(builder.functionRef(mark));
		});
		appendGcTraceCase(builder, value, WasmModuleSupport.typeId(Abstract("realtime_iterator")), function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(WasmLayout.ITERATOR_ARRAY_OFFSET));
			builder.call(builder.functionRef(mark));
		});
		appendGcTraceCase(builder, value, WasmLayout.CLOSURE_TYPE_ID, function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET));
			builder.call(builder.functionRef(mark));
		});
		appendGcConservativeTrace(builder, value, header, entryCount, entryIndex, mark);
		builder.return_();
		module.setFunction(index, builder.finish());
		return index;
	}

	static function appendGcTraceCase(builder:WasmFunctionBuilder, value:WasmLocalRef, id:Int, traceBody:WasmFunctionBuilder->Void):Void {
		builder.localGet(value);
		builder.emit(I32Load(0));
		builder.i32Const(id);
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			traceBody(builder);
			builder.return_();
		});
	}

	static function appendGcBackingTraceCase(builder:WasmFunctionBuilder, backingType:WasmLocalRef, id:Int, traceBody:WasmFunctionBuilder->Void):Void {
		builder.localGet(backingType);
		builder.emit(I32Load(0));
		builder.i32Const(id);
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			traceBody(builder);
			builder.return_();
		});
	}

	static function appendGcArrayContents(builder:WasmFunctionBuilder, value:WasmLocalRef, backingType:WasmLocalRef, entryCount:WasmLocalRef,
			entryIndex:WasmLocalRef, mark:Int):Void {
		builder.localGet(backingType);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(entryCount);
		builder.i32Const(0);
		builder.localSet(entryIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(entryIndex);
				builder.localGet(entryCount);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(value);
					builder.localGet(entryIndex);
					builder.i32Const(4);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.call(builder.functionRef(mark));
					builder.localGet(entryIndex);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(entryIndex);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
	}

	static function appendGcMapContents(builder:WasmFunctionBuilder, value:WasmLocalRef, backingType:WasmLocalRef, entryCount:WasmLocalRef,
			entryIndex:WasmLocalRef, mark:Int, mapName:String):Void {
		var keyType = WasmLinearRuntime.mapKeyType(mapName),
			valueType = WasmLinearRuntime.mapValueType(mapName),
			entrySize = WasmLinearRuntime.mapEntrySize(valueType),
			valueOffset = WasmLinearRuntime.mapValueOffset(valueType);
		builder.localGet(backingType);
		builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
		builder.localSet(entryCount);
		builder.i32Const(0);
		builder.localSet(entryIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(entryIndex);
				builder.localGet(entryCount);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					if (WasmTarget.isReference(keyType)) {
						builder.localGet(value);
						builder.localGet(entryIndex);
						builder.i32Const(entrySize);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.emit(I32Load(0));
						builder.call(builder.functionRef(mark));
					}
					if (WasmTarget.isReference(valueType)) {
						builder.localGet(value);
						builder.localGet(entryIndex);
						builder.i32Const(entrySize);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.emit(I32Load(valueOffset));
						builder.call(builder.functionRef(mark));
					}
					builder.localGet(entryIndex);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(entryIndex);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
	}

	static function appendGcConservativeTrace(builder:WasmFunctionBuilder, value:WasmLocalRef, header:WasmLocalRef, entryCount:WasmLocalRef,
			entryIndex:WasmLocalRef, mark:Int):Void {
		builder.localGet(header);
		builder.emit(I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET));
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.localSet(entryCount);
		builder.i32Const(0);
		builder.localSet(entryIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(entryIndex);
				builder.localGet(entryCount);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(value);
					builder.localGet(entryIndex);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.call(builder.functionRef(mark));
					builder.localGet(entryIndex);
					builder.i32Const(4);
					builder.i32Add();
					builder.localSet(entryIndex);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
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
			builder = new WasmFunctionBuilder("__haxeon_gc_collect", type),
			rootFrame = builder.local("rootFrame", I32),
			rootCount = builder.local("rootCount", I32),
			rootIndex = builder.local("rootIndex", I32),
			blockCursor = builder.local("blockCursor", I32),
			previousFreeBlock = builder.local("previousFreeBlock", I32),
			flags = builder.local("flags", I32),
			freeRunStart = builder.local("freeRunStart", I32),
			freeRunSize = builder.local("freeRunSize", I32),
			pendingBlock = builder.local("pendingBlock", I32);
		builder.globalGet(builder.global(heapTop));
		builder.globalSet(builder.global(markStackTop));
		if (collectionCount >= 0) {
			builder.globalGet(builder.global(collectionCount));
			builder.i32Const(1);
			builder.i32Add();
			builder.globalSet(builder.global(collectionCount));
		}
		builder.globalGet(builder.global(rootFrameTop));
		builder.localSet(rootFrame);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(rootFrame);
				builder.i32Eqz();
				builder.ifElse(function(builder) {
					builder.emit(Br(2));
				}, function(builder) {
					builder.localGet(rootFrame);
					builder.emit(I32Load(WasmLayout.ROOT_COUNT_OFFSET));
					builder.localSet(rootCount);
					builder.i32Const(0);
					builder.localSet(rootIndex);
					builder.block(function(builder) {
						builder.loop(function(builder) {
							builder.localGet(rootIndex);
							builder.localGet(rootCount);
							builder.emit(I32LtS);
							builder.ifElse(function(builder) {
								builder.localGet(rootFrame);
								builder.i32Const(WasmLayout.ROOT_VALUES_OFFSET);
								builder.i32Add();
								builder.localGet(rootIndex);
								builder.i32Const(4);
								builder.emit(I32Mul);
								builder.i32Add();
								builder.emit(I32Load(0));
								builder.call(builder.functionRef(mark));
								builder.localGet(rootIndex);
								builder.i32Const(1);
								builder.i32Add();
								builder.localSet(rootIndex);
								builder.emit(Br(1));
							}, function(builder) {
								builder.emit(Br(2));
							});
						});
					});
					builder.localGet(rootFrame);
					builder.emit(I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
					builder.localSet(rootFrame);
					builder.emit(Br(1));
				});
			});
		});
		for (global in rootGlobals) {
			builder.globalGet(builder.global(global));
			builder.call(builder.functionRef(mark));
		}
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.globalGet(builder.global(markStackTop));
				builder.globalGet(builder.global(heapTop));
				builder.emit(I32LeS);
				builder.emit(BrIf(1));
				builder.globalGet(builder.global(markStackTop));
				builder.i32Const(4);
				builder.i32Sub();
				builder.globalSet(builder.global(markStackTop));
				builder.globalGet(builder.global(markStackTop));
				builder.emit(I32Load(0));
				builder.localSet(pendingBlock);
				builder.globalGet(builder.global(markStackTop));
				builder.i32Const(0);
				builder.emit(I32Store(0));
				builder.localGet(pendingBlock);
				builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
				builder.i32Add();
				builder.call(builder.functionRef(trace));
				builder.emit(Br(0));
			});
		});
		function appendFreeRun(builder:WasmFunctionBuilder):Void {
			builder.localGet(freeRunSize);
			builder.i32Eqz();
			builder.if_(function(builder) {
				builder.localGet(blockCursor);
				builder.localSet(freeRunStart);
			});
			builder.localGet(freeRunSize);
			builder.localGet(previousFreeBlock);
			builder.i32Add();
			builder.localSet(freeRunSize);
		}
		function flushFreeRun(builder:WasmFunctionBuilder):Void {
			builder.localGet(freeRunSize);
			builder.i32Eqz();
			builder.i32Eqz();
			builder.if_(function(builder) {
				builder.localGet(freeRunStart);
				builder.localGet(freeRunSize);
				builder.emit(I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET));
				builder.localGet(freeRunStart);
				builder.i32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET);
				builder.i32Add();
				builder.i32Const(WasmLayout.GC_BLOCK_MAGIC);
				builder.emit(I32Store(0));
				builder.localGet(freeRunStart);
				builder.i32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET);
				builder.i32Add();
				builder.i32Const(0);
				builder.emit(I32Store(0));
				builder.localGet(freeRunStart);
				builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
				builder.i32Add();
				builder.globalGet(builder.global(freeHead));
				builder.emit(I32Store(0));
				builder.localGet(freeRunStart);
				builder.globalSet(builder.global(freeHead));
			});
		}
		builder.i32Const(0);
		builder.globalSet(builder.global(freeHead));
		builder.i32Const(heapStart);
		builder.localSet(blockCursor);
		builder.i32Const(0);
		builder.localSet(freeRunStart);
		builder.i32Const(0);
		builder.localSet(freeRunSize);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(blockCursor);
				builder.globalGet(builder.global(heapTop));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(blockCursor);
					builder.emit(I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET));
					builder.localSet(previousFreeBlock);
					builder.localGet(previousFreeBlock);
					builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
					builder.emit(I32LtS);
					builder.if_(function(builder) builder.emit(Unreachable));
					builder.localGet(previousFreeBlock);
					builder.i32Const(7);
					builder.emit(I32And);
					builder.i32Eqz();
					builder.i32Eqz();
					builder.if_(function(builder) builder.emit(Unreachable));
					builder.localGet(previousFreeBlock);
					builder.globalGet(builder.global(heapTop));
					builder.localGet(blockCursor);
					builder.i32Sub();
					builder.emit(I32LeS);
					builder.i32Eqz();
					builder.if_(function(builder) builder.emit(Unreachable));
					builder.localGet(blockCursor);
					builder.emit(I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET));
					builder.localSet(flags);
					builder.localGet(flags);
					builder.i32Const(WasmLayout.GC_BLOCK_MAGIC_MASK);
					builder.emit(I32And);
					builder.i32Const(WasmLayout.GC_BLOCK_MAGIC);
					builder.emit(I32Eq);
					builder.i32Eqz();
					builder.if_(function(builder) builder.emit(Unreachable));
					builder.localGet(flags);
					builder.i32Const(WasmLayout.GC_BLOCK_ALLOCATED);
					builder.emit(I32And);
					builder.ifElse(function(builder) {
						builder.localGet(flags);
						builder.i32Const(WasmLayout.GC_BLOCK_MARKED);
						builder.emit(I32And);
						builder.ifElse(function(builder) {
							flushFreeRun(builder);
							builder.i32Const(0);
							builder.localSet(freeRunStart);
							builder.i32Const(0);
							builder.localSet(freeRunSize);
							builder.localGet(blockCursor);
							builder.i32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET);
							builder.i32Add();
							builder.localGet(flags);
							builder.i32Const(WasmLayout.GC_BLOCK_CLEAR_MARKED_MASK);
							builder.emit(I32And);
							builder.emit(I32Store(0));
						}, function(builder) {
							appendFreeRun(builder);
						});
					}, function(builder) {
						appendFreeRun(builder);
					});
					builder.localGet(blockCursor);
					builder.localGet(previousFreeBlock);
					builder.i32Add();
					builder.localSet(blockCursor);
					builder.emit(Br(1));
				}, function(builder) {
					builder.emit(Br(2));
				});
			});
		});
		flushFreeRun(builder);
		builder.return_();
		return module.addFunction(builder.finish());
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
