package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Byte-addressed scalar and reference access for Wasm32 inline arrays. */
class WasmLinearValueArrays {
	public static function register(context:WasmLinearContext, used:Map<String, Bool>):Void {
		WasmLinearLaneStorage.register(context);
		var retypeAllocator = -1;
		for (native in context.program.natives) if (used.exists(native.name) && native.symbol == "__value_array_retype") {
			var alloc:IrNative = {name:"$linear-value-array:retype-allocate", library:"haxeon_runtime", symbol:"__value_array_alloc",
				arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
			retypeAllocator = context.module.addFunction(allocate(context.module, alloc, context.allocatorFunction));
			break;
		}
		for (native in context.program.natives) if (used.exists(native.name) && supports(native.symbol)) {
			if (compiler.backend.wasm.WasmValueLaneRuntime.bind(context.functions, native)) continue;
			var fn = native.symbol == "__value_array_retype" ? retype(context.module, native, retypeAllocator) :
				build(context.module, native, context.allocatorFunction);
			if (native.symbol != "__value_array_alloc" && native.symbol != "__value_array_retype") {
				var prefix = resolveForward(0);
				for (index in 0...prefix.length) fn.body.insert(index, prefix[index]);
			}
			context.functions.set(native.name, context.module.addFunction(fn));
		}
	}

	static function supports(symbol:String):Bool return switch symbol {
		case "__value_array_read_i32", "__value_array_write_i32", "__value_array_read_i64", "__value_array_write_i64",
			"__value_array_read_bool", "__value_array_write_bool", "__value_array_read_f32", "__value_array_write_f32",
			"__value_array_read_f64", "__value_array_write_f64", "__value_array_read_ptr", "__value_array_write_ptr",
			"__value_array_read_type", "__value_array_write_type", "__value_array_read_callback", "__value_array_write_callback",
			"__value_array_read_ref", "__value_array_write_ref", "__value_array_clear_ref", "__value_array_clear_scalar",
			"__value_array_validate", "__value_array_is_initialized", "__value_array_mark", "__value_array_alloc", "__value_array_set_bridge",
			"__value_array_ensure", "__value_array_clear", "__value_array_resize", "__value_array_insert_empty", "__value_array_copy", "__value_array_slice", "__value_array_reverse",
			"__value_array_concat", "__value_array_splice", "__value_array_remove_at", "__value_array_retype": true;
		default: false;
	};

	/** A converted Dynamic array keeps its original header as a forwarding handle. */
	public static function resolveForward(array:Int):Array<WasmInstruction> return [LocalGet(array), I32Eqz, I32Eqz, If(null),
		LocalGet(array), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_FORWARD_MARKER), I32Eq, If(null),
		LocalGet(array), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalSet(array), End, End];

	public static function syncForwardLength():Array<WasmInstruction> return [LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_FORWARD_HEADER_OFFSET), I32Eqz, I32Eqz, If(null),
		LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_FORWARD_HEADER_OFFSET), LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
		I32Store(WasmLayout.ARRAY_LENGTH_OFFSET), End];

	static function retype(module:compiler.backend.wasm.WasmModule.WasmModule, native:IrNative, allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 9 || allocator < 0) throw "Invalid Wasm32 value-array retype";
		var b = new WasmFunctionBuilder(native.name, {parameters:[for (_ in native.arguments) I32], results:[I32]}),
			resolved = b.local("resolved", I32), index = b.local("index", I32), size = b.local("size", I32),
			item = b.local("item", I32), candidate = b.local("candidate", I32),
			accept = module.typeIndex({parameters:[I32], results:[I32]}), write = module.typeIndex({parameters:[I32,I32,I32], results:[]});
		b.emitAll([LocalGet(0), I32Eqz, If(null), I32Const(0), Return, End, LocalGet(0), LocalSet(resolved)]);
		b.emitAll(resolveForward(resolved));
		b.emitAll([LocalGet(resolved), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, If(null)]);
		for (pair in [{offset:WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET,arg:1}, {offset:WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET,arg:2},
				{offset:WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET,arg:3}, {offset:WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET,arg:5}]) {
			b.emitAll([LocalGet(resolved), I32Load(pair.offset), LocalGet(pair.arg), I32Eq, I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		}
		b.emitAll([LocalGet(4), I32Const(32), I32Eq, LocalGet(4), I32Const(64), I32Eq, I32Or, I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(0), Return, End, LocalGet(0), I32Load(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET), I32Const(module.runtimeTypeId(Dyn)), I32Eq,
			LocalGet(0), I32Load(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET), LocalGet(1), I32Eq, I32Or, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		for (arg in [6,7,8]) { b.emitAll([LocalGet(arg), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End); }
		b.emitAll([LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(size), Block(null), Loop(null), LocalGet(index), LocalGet(size), I32Eq, BrIf(1),
			LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(index), I32Const(4), I32Mul, I32Add, I32Load(0), LocalSet(item),
			LocalGet(item), LocalGet(8), I32Const(-2), I32And, I32Load(WasmLayout.STATIC_CLOSURE_FUNCTION_OFFSET), CallIndirect(accept), I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			LocalGet(size), LocalGet(1), LocalGet(2), LocalGet(3), LocalGet(4), LocalGet(5), Call(allocator), LocalSet(candidate)]);
		for (pair in [{offset:WasmLayout.VALUE_ARRAY_READ_BRIDGE_OFFSET,arg:6}, {offset:WasmLayout.VALUE_ARRAY_WRITE_BRIDGE_OFFSET,arg:7},
				{offset:WasmLayout.VALUE_ARRAY_ACCEPTS_BRIDGE_OFFSET,arg:8}]) b.emitAll([LocalGet(candidate), LocalGet(pair.arg), I32Store(pair.offset)]);
		b.emitAll([I32Const(0), LocalSet(index), Block(null), Loop(null), LocalGet(index), LocalGet(size), I32Eq, BrIf(1),
			LocalGet(candidate), LocalGet(index), LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(index), I32Const(4), I32Mul, I32Add, I32Load(0),
			LocalGet(7), I32Const(-2), I32And, I32Load(WasmLayout.STATIC_CLOSURE_FUNCTION_OFFSET), CallIndirect(write), LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			LocalGet(candidate), LocalGet(0), I32Store(WasmLayout.VALUE_ARRAY_FORWARD_HEADER_OFFSET), LocalGet(0), LocalGet(candidate),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(0), LocalGet(1), I32Store(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET),
			LocalGet(0), I32Const(WasmLayout.VALUE_ARRAY_FORWARD_MARKER), I32Store(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), LocalGet(0), Return]);
		return b.finish();
	}

	public static function build(module:compiler.backend.wasm.WasmModule.WasmModule, native:IrNative, allocator:Int = -1):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.symbol == "__value_array_alloc") return allocate(module, native, allocator);
		if (native.symbol == "__value_array_set_bridge") return setBridge(native);
		if (native.symbol == "__value_array_validate" || native.symbol == "__value_array_is_initialized" || native.symbol == "__value_array_mark")
			return buildValidity(native);
		var symbol = native.symbol, reference = StringTools.endsWith(symbol, "_ref"), clear = StringTools.startsWith(symbol, "__value_array_clear_"),
			write = clear || StringTools.startsWith(symbol, "__value_array_write_"), suffix = reference ? "ref" : clear ? "clear" :
				symbol.substr(write ? "__value_array_write_".length : "__value_array_read_".length),
			integer = suffix == "i32" || suffix == "i64", variableWidth = integer || suffix == "ptr" || suffix == "type" || suffix == "clear";
		var expected = 3 + (variableWidth ? 1 : 0) + (write && !clear ? 1 : 0) + (!write && integer ? 1 : 0);
		if (native.arguments.length != expected) throw 'Invalid Wasm32 value-array access $symbol';
		var results:Array<WasmValueType> = (switch (native.result) { case Void: true; default: false; }) ? [] : [WasmModuleSupport.requireValueType(native.result)],
			builder = new WasmFunctionBuilder(native.name, {parameters:[for (arg in native.arguments) WasmModuleSupport.requireValueType(arg)], results:results}),
			width = builder.local("width", I32), address = builder.local("address", I32), bits = builder.local("bits", I64);
		// Validate the array and logical element index before dereferencing the header.
		builder.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
		builder.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(1), I32Const(0), I32LtS, I32Or, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalGet(1), I32LeS, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
		if (!write) appendValidityCheck(builder);
		if (reference) {
			builder.emitAll([LocalGet(2), I32Const(0), I32LtS, LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET),
				LocalGet(2), I32LeS, I32Or, If(null)]); WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
			builder.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET), LocalGet(1),
				LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Mul, LocalGet(2), I32Add, I32Const(4), I32Mul, I32Add]);
			if (write) builder.emitAll([clear ? I32Const(0) : LocalGet(3), I32Store(0)]); else builder.emit(I32Load(0));
			builder.return_(); return builder.finish();
		}
		builder.emit(variableWidth ? LocalGet(3) : I32Const(suffix == "bool" ? 8 : suffix == "f32" || suffix == "callback" ? 32 : 64));
		builder.localSet(width);
		builder.emitAll([LocalGet(2), I32Const(0), I32LtS, LocalGet(2), I32Const(7), I32And, I32Or,
			LocalGet(width), I32Const(8), I32Eq, LocalGet(width), I32Const(16), I32Eq, I32Or, LocalGet(width), I32Const(32), I32Eq, I32Or,
			LocalGet(width), I32Const(64), I32Eq, I32Or, I32Eqz, I32Or,
			LocalGet(2), I64ExtendI32S, LocalGet(width), I64ExtendI32S, I64Add,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I64ExtendI32U, I64LeS, I32Eqz, I32Or]);
		if (suffix == "i32") builder.emitAll([LocalGet(width), I32Const(32), I32LeS, I32Eqz, I32Or]);
		if (suffix == "ptr" || suffix == "type") builder.emitAll([LocalGet(width), I32Const(32), I32Eq, I32Eqz, I32Or]);
		builder.emit(If(null)); WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
		builder.emitAll([LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(1),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I32Const(8), I32DivS, I32Mul,
			LocalGet(2), I32Const(8), I32DivS, I32Add, I32Add, LocalSet(address)]);
		if (write) {
			if (!clear) {
				builder.emit(LocalGet(variableWidth ? 4 : 3));
				builder.emitAll(switch suffix {
					case "i32", "bool", "ptr", "type", "callback": [I64ExtendI32U];
					case "i64": [];
					case "f32": [F32DemoteF64, I32ReinterpretF32, I64ExtendI32U];
					case "f64": [I64ReinterpretF64];
					default: throw 'Unsupported Wasm32 value-array scalar $suffix';
				});
				builder.localSet(bits);
			}
			for (size in [8, 16, 32, 64]) {
				builder.emitAll([LocalGet(width), I32Const(size), I32Eq, If(null), LocalGet(address), LocalGet(bits)]);
				if (size != 64) builder.emit(I32WrapI64);
				builder.emit(switch size {case 8:I32Store8(0); case 16:I32Store16(0); case 32:I32Store(0); default:I64Store(0);});
				builder.emit(End);
			}
		} else {
			for (size in [8, 16, 32, 64]) {
				builder.emitAll([LocalGet(width), I32Const(size), I32Eq, If(null), LocalGet(address),
					switch size {case 8:I32Load8U(0); case 16:I32Load16U(0); case 32:I32Load(0); default:I64Load(0);}]);
				if (size != 64) builder.emit(I64ExtendI32U);
				builder.emitAll([LocalSet(bits), End]);
			}
			if (integer) builder.emitAll([LocalGet(4), If(null), LocalGet(bits), I64Const(64), LocalGet(width), I64ExtendI32U, I64Sub, I64Shl,
				I64Const(64), LocalGet(width), I64ExtendI32U, I64Sub, I64ShrS, LocalSet(bits), End]);
			builder.localGet(bits);
			builder.emitAll(switch suffix {
				case "i32", "ptr", "type", "callback": [I32WrapI64];
				case "bool": [I64Eqz, I32Eqz];
				case "i64": [];
				case "f32": [I32WrapI64, F32ReinterpretI32, F64PromoteF32];
				case "f64": [F64ReinterpretI64];
				default: throw 'Unsupported Wasm32 value-array scalar $suffix';
			});
		}
		builder.return_(); return builder.finish();
	}

	public static function newLike(allocator:Int, name:String):compiler.backend.wasm.WasmModule.WasmFunction {
		var b = new WasmFunctionBuilder(name, {parameters:[I32,I32], results:[I32]}), result = b.local("result", I32);
		b.emitAll([LocalGet(1), LocalGet(0), I32Load(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Const(32), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET),
			Call(allocator), LocalSet(result)]);
		for (offset in [WasmLayout.VALUE_ARRAY_READ_BRIDGE_OFFSET, WasmLayout.VALUE_ARRAY_WRITE_BRIDGE_OFFSET, WasmLayout.VALUE_ARRAY_ACCEPTS_BRIDGE_OFFSET])
			b.emitAll([LocalGet(result), LocalGet(0), I32Load(offset), I32Store(offset)]);
		b.emitAll([LocalGet(result), Return]);
		return b.finish();
	}


	public static function replaceCapacity(native:IrNative, allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || allocator < 0) throw "Invalid Wasm32 value-array growth";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[]}), oldCapacity = b.local("old-capacity", I32),
			capacity = b.local("capacity", I32), oldPayload = b.local("old-payload", I32), payload = b.local("payload", I32),
			scalarBytes = b.local("scalar-bytes", I32), refBytes = b.local("reference-bytes", I32), total = b.local("checked-size", I64),
			scalar = b.local("new-scalar", I32), references = b.local("new-references", I32);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET), LocalSet(oldCapacity), LocalGet(1), LocalSet(capacity)]);
		for (pair in [{cap:oldCapacity, dest:oldPayload}, {cap:capacity, dest:payload}]) {
			b.emitAll([LocalGet(pair.cap), I64ExtendI32U, LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I64ExtendI32U,
				I64Mul, I64Const(31), I64Add, I64Const(32), I64DivS, I64Const(4), I64Mul, LocalTee(total), I64Const(0x7ffffff0), I64LeS,
				I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b);
			b.emitAll([End, LocalGet(total), I32WrapI64, LocalSet(pair.dest)]);
		}
		b.emitAll([LocalGet(payload), I64ExtendI32U, LocalSet(total), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null),
			LocalGet(total), LocalGet(capacity), I64ExtendI32U, I64Const(31), I64Add, I64Const(32), I64DivS, I64Const(4), I64Mul, I64Add, LocalSet(total), End,
			LocalGet(total), I64Const(0x7ffffff0), I64LeS, I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(total), I32WrapI64, LocalSet(scalarBytes), LocalGet(capacity), I64ExtendI32U,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I64ExtendI32U, I64Mul, I64Const(4), I64Mul, LocalTee(total),
			I64Const(0x7ffffff0), I64LeS, I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(total), I32WrapI64, LocalSet(refBytes), LocalGet(scalarBytes), Call(allocator), LocalSet(scalar),
			LocalGet(scalar), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET), I32Add,
			LocalGet(scalar), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET), I32Add,
			I32Load(0), I32Const(WasmLayout.GC_BLOCK_CLEAR_SCAN_MASK), I32And, I32Store(0),
			LocalGet(refBytes), I32Eqz, I32Eqz, If(null), LocalGet(refBytes), Call(allocator), LocalSet(references)]);
		WasmLinearGc.appendGcContainerOwner(b.body, references, 0);
		b.emitAll([End, LocalGet(scalar), LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(oldPayload), MemoryCopy,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null), LocalGet(scalar), LocalGet(payload), I32Add,
			LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(oldPayload), I32Add,
			LocalGet(oldCapacity), I64ExtendI32U, I64Const(31), I64Add, I64Const(32), I64DivS, I64Const(4), I64Mul, I32WrapI64, MemoryCopy, End,
			LocalGet(refBytes), I32Eqz, I32Eqz, If(null), LocalGet(references), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET),
			LocalGet(oldCapacity), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Mul, I32Const(4), I32Mul, MemoryCopy, End,
			LocalGet(0), LocalGet(scalar), I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0), LocalGet(references), I32Store(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET),
			LocalGet(0), LocalGet(capacity), I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET)]);
		b.emit(Return);
		return b.finish();
	}

	public static function allocate(module:compiler.backend.wasm.WasmModule.WasmModule, native:IrNative, allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 6 || allocator < 0) throw "Invalid Wasm32 value-array allocator";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32,I32,I32,I32,I32], results:[I32]}),
			capacity = b.local("capacity", I32), scalarBytes = b.local("scalar-bytes", I32), refBytes = b.local("reference-bytes", I32),
			total = b.local("checked-size", I64), header = b.local("header", I32), scalar = b.local("scalar", I32), references = b.local("references", I32);
		b.emitAll([LocalGet(0), I32Const(0), I32LtS, LocalGet(2), I32Const(0), I32LtS, I32Or,
			LocalGet(2), I32Const(7), I32And, I32Or, LocalGet(3), I32Const(0), I32LtS, I32Or,
			LocalGet(4), I32Const(32), I32Eq, LocalGet(4), I32Const(64), I32Eq, I32Or, I32Eqz, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Const(4), I32LtS, If(I32), I32Const(4), Else, LocalGet(0), End, LocalSet(capacity),
			LocalGet(capacity), I64ExtendI32U, LocalGet(2), I64ExtendI32U, I64Mul, I64Const(31), I64Add, I64Const(32), I64DivS,
			I64Const(4), I64Mul, LocalSet(total), LocalGet(5), If(null), LocalGet(total), LocalGet(capacity), I64ExtendI32U,
			I64Const(31), I64Add, I64Const(32), I64DivS, I64Const(4), I64Mul, I64Add, LocalSet(total), End,
			LocalGet(total), I64Const(0x7ffffff0), I64LeS, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(total), I32WrapI64, LocalSet(scalarBytes),
			LocalGet(capacity), I64ExtendI32U, LocalGet(3), I64ExtendI32U, I64Mul, I64Const(4), I64Mul, LocalSet(total),
			LocalGet(total), I64Const(0x7ffffff0), I64LeS, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(total), I32WrapI64, LocalSet(refBytes),
			I32Const(WasmLayout.VALUE_ARRAY_HEADER_SIZE), Call(allocator), LocalSet(header),
			LocalGet(header), I32Const(module.runtimeTypeId(Array(Dyn))), I32Store(0),
			LocalGet(header), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Store(WasmLayout.VALUE_ARRAY_MARKER_OFFSET),
			LocalGet(header), LocalGet(0), I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(header), LocalGet(capacity), I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(header), LocalGet(1), I32Store(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET),
			LocalGet(header), LocalGet(2), I32Store(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET),
			LocalGet(header), LocalGet(3), I32Store(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET),
			LocalGet(header), LocalGet(5), I32Store(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET),
			LocalGet(scalarBytes), Call(allocator), LocalSet(scalar),
			LocalGet(scalar), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET), I32Add,
			LocalGet(scalar), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET), I32Add,
			I32Load(0), I32Const(WasmLayout.GC_BLOCK_CLEAR_SCAN_MASK), I32And, I32Store(0),
			LocalGet(header), LocalGet(scalar), I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(refBytes), I32Eqz, I32Eqz, If(null), LocalGet(refBytes), Call(allocator), LocalSet(references)]);
		WasmLinearGc.appendGcContainerOwner(b.body, references, header);
		b.emitAll([LocalGet(header), LocalGet(references), I32Store(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET), End, LocalGet(header), Return]);
		return b.finish();
	}

	static function setBridge(native:IrNative):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 4) throw "Invalid Wasm32 value-array bridge";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32,I32,I32], results:[]});
		b.emitAll([LocalGet(0), I32Eqz, LocalGet(1), I32Eqz, I32Or, LocalGet(2), I32Eqz, I32Or, LocalGet(3), I32Eqz, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		for (pair in [{offset:WasmLayout.VALUE_ARRAY_READ_BRIDGE_OFFSET,arg:1}, {offset:WasmLayout.VALUE_ARRAY_WRITE_BRIDGE_OFFSET,arg:2},
				{offset:WasmLayout.VALUE_ARRAY_ACCEPTS_BRIDGE_OFFSET,arg:3}]) b.emitAll([LocalGet(0), LocalGet(pair.arg), I32Store(pair.offset)]);
		b.return_(); return b.finish();
	}

	static function buildValidity(native:IrNative):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2) throw 'Invalid Wasm32 value-array validity operation ${native.symbol}';
		var builder = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:(switch (native.result) { case Void: true; default: false; }) ? [] : [I32]}),
			address = builder.local("validity-address", I32), mask = builder.local("validity-mask", I32);
		builder.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
		builder.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(1), I32Const(0), I32LtS, I32Or, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalGet(1), I32LeS, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(builder); builder.emit(End);
		builder.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), I32Eqz, If(null)]);
		if (native.symbol == "__value_array_is_initialized") builder.emit(I32Const(1));
		builder.emitAll([Return, End]);
		appendValidityAddress(builder);
		builder.localSet(address);
		builder.emitAll([I32Const(1), LocalGet(1), I32Const(7), I32And, I32Shl, LocalSet(mask)]);
		if (native.symbol == "__value_array_mark") builder.emitAll([LocalGet(address), LocalGet(address), I32Load8U(0), LocalGet(mask), I32Or, I32Store8(0)]);
		else {
			builder.emitAll([LocalGet(address), I32Load8U(0), LocalGet(mask), I32And, I32Eqz]);
			if (native.symbol == "__value_array_validate") { builder.emit(If(null)); WasmLinearRuntime.runtimeFailure(builder); builder.emit(End); }
			else builder.emit(I32Eqz);
		}
		builder.return_(); return builder.finish();
	}

	public static function appendValidityAddress(builder:WasmFunctionBuilder, index:Int = 1, array:Int = 0):Void {
		builder.emitAll([LocalGet(array), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(array), I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET), I64ExtendI32U,
			LocalGet(array), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I64ExtendI32U, I64Mul, I64Const(31), I64Add,
			I64Const(32), I64DivS, I64Const(4), I64Mul, I32WrapI64, I32Add, LocalGet(index), I32Const(8), I32DivS, I32Add]);
	}

	/** Validity bits follow the capacity-sized, 32-bit-aligned payload. */
	static function appendValidityCheck(builder:WasmFunctionBuilder):Void {
		builder.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null)]);
		appendValidityAddress(builder);
		builder.emitAll([I32Load8U(0), LocalGet(1), I32Const(7), I32And, I32ShrU, I32Const(1), I32And, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(builder); builder.emitAll([End, End]);
	}
}
