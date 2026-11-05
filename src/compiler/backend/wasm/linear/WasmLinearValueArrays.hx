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
	public static function register(context:WasmLinearContext):Void {
		var needsResize = false, needsInsert = false, needsCopy = false, needsReverse = false, needsSplice = false, needsRetype = false;
		for (native in context.program.natives) {
			if (native.symbol == "__value_array_resize") needsResize = true;
			if (native.symbol == "__value_array_insert_empty") needsInsert = true;
			if (native.symbol == "__value_array_copy" || native.symbol == "__value_array_slice" || native.symbol == "__value_array_concat") needsCopy = true;
			if (native.symbol == "__value_array_splice") { needsCopy = true; needsResize = true; needsSplice = true; }
			if (native.symbol == "__value_array_remove_at") { needsCopy = true; needsResize = true; needsSplice = true; }
			if (native.symbol == "__value_array_reverse") needsReverse = true;
			if (native.symbol == "__value_array_retype") needsRetype = true;
		}
		var ensureIndex = -1, clearIndex = -1, moveIndex = -1, newLikeIndex = -1, swapIndex = -1, resizeIndex = -1;
		if (needsResize || needsInsert) {
			var a:IrType = Array(Dyn);
			var ensureNative:IrNative = {name:"$linear-value-array:ensure", library:"haxeon_runtime", symbol:"__value_array_ensure", arguments:[a,I32], result:Void};
			var clearNative:IrNative = {name:"$linear-value-array:clear", library:"haxeon_runtime", symbol:"__value_array_clear", arguments:[a,I32], result:Void};
			ensureIndex = context.module.addFunction(ensure(ensureNative, context.allocatorFunction));
			clearIndex = context.module.addFunction(clearElement(clearNative));
			context.functions.set("$linear-value-array:ensure", ensureIndex);
			context.functions.set("$linear-value-array:clear", clearIndex);
		}
		if (needsInsert || needsCopy) {
			moveIndex = context.module.addFunction(moveElement());
			context.functions.set("$linear-value-array:move-element", moveIndex);
		}
		if (needsReverse) swapIndex = context.module.addFunction(swapElements());
		if (needsCopy) {
			var a:IrType = Array(Dyn), alloc:IrNative = {name:"$linear-value-array:allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:a};
			newLikeIndex = context.module.addFunction(newLike(context.module.addFunction(allocate(context.module, alloc, context.allocatorFunction))));
			context.functions.set("$linear-value-array:new-like", newLikeIndex);
		}
		if (needsSplice) {
			var helper:IrNative = {name:"$linear-value-array:resize", library:"haxeon_runtime", symbol:"__value_array_resize", arguments:[Array(Dyn),I32], result:Void};
			resizeIndex = context.module.addFunction(resize(helper, ensureIndex, clearIndex));
		}
		var retypeAllocator = -1;
		if (needsRetype) {
			var alloc:IrNative = {name:"$linear-value-array:retype-allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
			retypeAllocator = context.module.addFunction(allocate(context.module, alloc, context.allocatorFunction));
		}
		if (needsInsert) {
			var insertNative:IrNative = {name:"$linear-value-array:insert", library:"haxeon_runtime", symbol:"__value_array_insert_empty", arguments:[Array(Dyn),I32], result:I32};
			context.functions.set(insertNative.name, context.module.addFunction(insert(insertNative, ensureIndex, clearIndex, moveIndex)));
		}
		if (needsRetype || needsInsert || needsCopy) {
			var valid:IrNative = {name:"$linear-value-array:initialized", library:"haxeon_runtime", symbol:"__value_array_is_initialized", arguments:[Array(Dyn),I32], result:Bool};
			context.functions.set(valid.name, context.module.addFunction(buildValidity(valid)));
		}
		for (native in context.program.natives) if (supports(native.symbol)) {
			var fn = native.symbol == "__value_array_retype" ? retype(context.module, native, retypeAllocator) :
				build(context.module, native, context.allocatorFunction, ensureIndex, clearIndex, moveIndex, newLikeIndex, swapIndex, resizeIndex);
			if (native.symbol != "__value_array_alloc" && native.symbol != "__value_array_retype") {
				var prefix = resolveForward(0);
				if (native.symbol == "__value_array_concat") prefix = prefix.concat(resolveForward(1));
				for (index in 0...prefix.length) fn.body.insert(index, prefix[index]);
			}
			var index = context.module.addFunction(fn);
			context.functions.set(native.name, index);
			if (native.symbol == "__value_array_copy" || native.symbol == "__value_array_slice" || native.symbol == "__value_array_concat"
					|| native.symbol == "__value_array_splice" || native.symbol == "__value_array_remove_at" || native.symbol == "__value_array_reverse" || native.symbol == "__value_array_resize")
				context.functions.set("$linear-value-array:operation:" + native.symbol.substr("__value_array_".length), index);
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

	static function syncForwardLength():Array<WasmInstruction> return [LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_FORWARD_HEADER_OFFSET), I32Eqz, I32Eqz, If(null),
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

	public static function build(module:compiler.backend.wasm.WasmModule.WasmModule, native:IrNative, allocator:Int = -1, ensureIndex:Int = -1, clearIndex:Int = -1, moveIndex:Int = -1, newLikeIndex:Int = -1, swapIndex:Int = -1, resizeIndex:Int = -1):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.symbol == "__value_array_alloc") return allocate(module, native, allocator);
		if (native.symbol == "__value_array_ensure") return ensure(native, allocator);
		if (native.symbol == "__value_array_clear") return clearElement(native);
		if (native.symbol == "__value_array_resize") return resize(native, ensureIndex, clearIndex);
		if (native.symbol == "__value_array_insert_empty") return insert(native, ensureIndex, clearIndex, moveIndex);
		if (native.symbol == "__value_array_copy" || native.symbol == "__value_array_slice") return copyRange(native, newLikeIndex, moveIndex);
		if (native.symbol == "__value_array_reverse") return reverse(native, swapIndex);
		if (native.symbol == "__value_array_concat") return concat(native, newLikeIndex, moveIndex);
		if (native.symbol == "__value_array_splice") return splice(native, newLikeIndex, moveIndex, resizeIndex);
		if (native.symbol == "__value_array_remove_at") return removeAt(native, moveIndex, resizeIndex);
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

	/** Move one element between compatible arrays; callers choose the direction for overlap. */
	static function moveElement():compiler.backend.wasm.WasmModule.WasmFunction {
		var b = new WasmFunctionBuilder("$linear-value-array:move-element", {parameters:[I32,I32,I32,I32], results:[]}),
			stride = b.local("stride", I32), sourceBit = b.local("source-bit", I32), address = b.local("validity-address", I32), mask = b.local("mask", I32);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I32Const(8), I32DivS, LocalTee(stride), If(null),
			LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(1), LocalGet(stride), I32Mul, I32Add,
			LocalGet(2), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(3), LocalGet(stride), I32Mul, I32Add, LocalGet(stride), MemoryCopy, End,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Const(4), I32Mul, LocalTee(stride), If(null),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET), LocalGet(1), LocalGet(stride), I32Mul, I32Add,
			LocalGet(2), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET), LocalGet(3), LocalGet(stride), I32Mul, I32Add, LocalGet(stride), MemoryCopy, End,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null)]);
		appendValidityAddress(b, 3, 2);
		b.emitAll([I32Load8U(0), LocalGet(3), I32Const(7), I32And, I32ShrU, I32Const(1), I32And, LocalSet(sourceBit)]);
		appendValidityAddress(b, 1);
		b.emitAll([LocalSet(address), I32Const(1), LocalGet(1), I32Const(7), I32And, I32Shl, LocalSet(mask), LocalGet(address),
			LocalGet(address), I32Load8U(0), LocalGet(mask), I32Const(-1), I32Xor, I32And,
			LocalGet(sourceBit), LocalGet(1), I32Const(7), I32And, I32Shl, I32Or, I32Store8(0), End, Return]);
		return b.finish();
	}

	static function resize(native:IrNative, ensure:Int, clear:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || ensure < 0 || clear < 0) throw "Invalid Wasm32 value-array resize";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[]}), cursor = b.local("cursor", I32);
		b.emitAll([LocalGet(0), I32Eqz, LocalGet(1), I32Const(0), I32LtS, I32Or, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(cursor),
			LocalGet(cursor), LocalGet(1), I32LtS, If(null), LocalGet(0), LocalGet(1), I32Const(1), I32Sub, Call(ensure), Return, End,
			Block(null), Loop(null), LocalGet(cursor), LocalGet(1), I32LeS, BrIf(1), LocalGet(cursor), I32Const(1), I32Sub, LocalSet(cursor),
			LocalGet(0), LocalGet(cursor), Call(clear), Br(0), End, End, LocalGet(0), LocalGet(1), I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)]);
		b.emitAll(syncForwardLength()); b.emit(Return);
		return b.finish();
	}

	static function insert(native:IrNative, ensure:Int, clear:Int, move:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || ensure < 0 || clear < 0 || move < 0) throw "Invalid Wasm32 value-array insertion";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[I32]}), size = b.local("size", I32), cursor = b.local("cursor", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalTee(size), I32Const(0x7fffffff), I32Eq, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(1), I32Const(0), I32LtS, If(null), LocalGet(1), LocalGet(size), I32Add, LocalSet(1), End,
			LocalGet(1), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(1), End, LocalGet(size), LocalGet(1), I32LtS, If(null), LocalGet(size), LocalSet(1), End,
			LocalGet(0), LocalGet(size), Call(ensure), LocalGet(size), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(1), I32LeS, BrIf(1),
			LocalGet(0), LocalGet(cursor), LocalGet(0), LocalGet(cursor), I32Const(1), I32Sub, Call(move), LocalGet(cursor), I32Const(1), I32Sub, LocalSet(cursor), Br(0), End, End,
			LocalGet(0), LocalGet(1), Call(clear), LocalGet(1), Return]);
		return b.finish();
	}

	static function newLike(allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		var b = new WasmFunctionBuilder("$linear-value-array:new-like", {parameters:[I32,I32], results:[I32]}), result = b.local("result", I32);
		b.emitAll([LocalGet(1), LocalGet(0), I32Load(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Const(32), LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET),
			Call(allocator), LocalSet(result)]);
		for (offset in [WasmLayout.VALUE_ARRAY_READ_BRIDGE_OFFSET, WasmLayout.VALUE_ARRAY_WRITE_BRIDGE_OFFSET, WasmLayout.VALUE_ARRAY_ACCEPTS_BRIDGE_OFFSET])
			b.emitAll([LocalGet(result), LocalGet(0), I32Load(offset), I32Store(offset)]);
		b.emitAll([LocalGet(result), Return]);
		return b.finish();
	}

	static function swapElements():compiler.backend.wasm.WasmModule.WasmFunction {
		var b = new WasmFunctionBuilder("$linear-value-array:swap", {parameters:[I32,I32,I32], results:[]}),
			stride = b.local("stride", I32), cursor = b.local("cursor", I32), left = b.local("left", I32), right = b.local("right", I32),
			temp = b.local("temporary", I32), leftBit = b.local("left-bit", I32), rightBit = b.local("right-bit", I32);
		for (lane in [{data:WasmLayout.ARRAY_DATA_POINTER_OFFSET, stride:WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET, scalar:true},
				{data:WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET, stride:WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET, scalar:false}]) {
			b.emitAll([LocalGet(0), I32Load(lane.stride), I32Const(lane.scalar ? 8 : 4), lane.scalar ? I32DivS : I32Mul, LocalTee(stride), If(null),
				LocalGet(0), I32Load(lane.data), LocalGet(1), LocalGet(stride), I32Mul, I32Add, LocalSet(left),
				LocalGet(0), I32Load(lane.data), LocalGet(2), LocalGet(stride), I32Mul, I32Add, LocalSet(right), I32Const(0), LocalSet(cursor),
				Block(null), Loop(null), LocalGet(cursor), LocalGet(stride), I32Eq, BrIf(1),
				LocalGet(left), LocalGet(cursor), I32Add, I32Load8U(0), LocalSet(temp),
				LocalGet(left), LocalGet(cursor), I32Add, LocalGet(right), LocalGet(cursor), I32Add, I32Load8U(0), I32Store8(0),
				LocalGet(right), LocalGet(cursor), I32Add, LocalGet(temp), I32Store8(0), LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End, End]);
		}
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null)]);
		for (pair in [{index:1, dest:leftBit}, {index:2, dest:rightBit}]) {
			appendValidityAddress(b, pair.index);
			b.emitAll([I32Load8U(0), LocalGet(pair.index), I32Const(7), I32And, I32ShrU, I32Const(1), I32And, LocalSet(pair.dest)]);
		}
		b.emitAll([LocalGet(leftBit), LocalGet(rightBit), I32Eq, I32Eqz, If(null)]);
		for (index in [1,2]) {
			appendValidityAddress(b, index);
			b.emit(LocalSet(left));
			b.emitAll([LocalGet(left), LocalGet(left), I32Load8U(0), I32Const(1), LocalGet(index), I32Const(7), I32And, I32Shl, I32Xor, I32Store8(0)]);
		}
		b.emitAll([End, End, Return]);
		return b.finish();
	}

	static function reverse(native:IrNative, swap:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 1 || swap < 0) throw "Invalid Wasm32 value-array reverse";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32], results:[]}), left = b.local("left", I32), right = b.local("right", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), I32Const(1), I32Sub, LocalSet(right),
			Block(null), Loop(null), LocalGet(left), LocalGet(right), I32LtS, I32Eqz, BrIf(1), LocalGet(0), LocalGet(left), LocalGet(right), Call(swap),
			LocalGet(left), I32Const(1), I32Add, LocalSet(left), LocalGet(right), I32Const(1), I32Sub, LocalSet(right), Br(0), End, End, Return]);
		return b.finish();
	}

	static function copyRange(native:IrNative, newLike:Int, move:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		var slice = native.symbol == "__value_array_slice";
		if (native.arguments.length != (slice ? 3 : 1) || newLike < 0 || move < 0) throw "Invalid Wasm32 value-array copy";
		var b = new WasmFunctionBuilder(native.name, {parameters:[for (_ in native.arguments) I32], results:[I32]}),
			start = b.local("start", I32), end = b.local("end", I32), size = b.local("size", I32), cursor = b.local("cursor", I32), result = b.local("result", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(size)]);
		if (slice) {
			for (pair in [{arg:1, dest:start}, {arg:2, dest:end}]) b.emitAll([LocalGet(pair.arg), LocalSet(pair.dest),
				LocalGet(pair.dest), I32Const(0), I32LtS, If(null), LocalGet(pair.dest), LocalGet(size), I32Add, LocalSet(pair.dest), End,
				LocalGet(pair.dest), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(pair.dest), End,
				LocalGet(size), LocalGet(pair.dest), I32LtS, If(null), LocalGet(size), LocalSet(pair.dest), End]);
			b.emitAll([LocalGet(end), LocalGet(start), I32LtS, If(null), LocalGet(start), LocalSet(end), End]);
		} else b.emitAll([I32Const(0), LocalSet(start), LocalGet(size), LocalSet(end)]);
		b.emitAll([LocalGet(0), LocalGet(end), LocalGet(start), I32Sub, Call(newLike), LocalSet(result), Block(null), Loop(null),
			LocalGet(cursor), LocalGet(end), LocalGet(start), I32Sub, I32Eq, BrIf(1), LocalGet(result), LocalGet(cursor), LocalGet(0),
			LocalGet(start), LocalGet(cursor), I32Add, Call(move), LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			LocalGet(result), Return]);
		return b.finish();
	}

	static function concat(native:IrNative, newLike:Int, move:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || newLike < 0 || move < 0) throw "Invalid Wasm32 value-array concat";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[I32]}), leftSize = b.local("left-size", I32),
			rightSize = b.local("right-size", I32), cursor = b.local("cursor", I32), result = b.local("result", I32);
		b.emitAll([LocalGet(0), I32Eqz, LocalGet(1), I32Eqz, I32Or, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		for (array in [0, 1]) {
			b.emitAll([LocalGet(array), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
			WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		}
		for (offset in [WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET, WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET,
				WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET, WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET]) {
			b.emitAll([LocalGet(0), I32Load(offset), LocalGet(1), I32Load(offset), I32Eq, I32Eqz, If(null)]);
			WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		}
		b.emitAll([LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(leftSize), LocalGet(1), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(rightSize),
			LocalGet(leftSize), I64ExtendI32U, LocalGet(rightSize), I64ExtendI32U, I64Add, I64Const(0x7fffffff), I64LeS, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(0), LocalGet(leftSize), LocalGet(rightSize), I32Add, Call(newLike), LocalSet(result)]);
		for (side in [{array:0, count:leftSize, offset:false}, {array:1, count:rightSize, offset:true}]) {
			b.emitAll([I32Const(0), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(side.count), I32Eq, BrIf(1), LocalGet(result), LocalGet(cursor)]);
			if (side.offset) b.emitAll([LocalGet(leftSize), I32Add]);
			b.emitAll([LocalGet(side.array), LocalGet(cursor), Call(move), LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End]);
		}
		b.emitAll([LocalGet(result), Return]); return b.finish();
	}

	static function splice(native:IrNative, newLike:Int, move:Int, resize:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 3 || newLike < 0 || move < 0 || resize < 0) throw "Invalid Wasm32 value-array splice";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32,I32], results:[I32]}), size = b.local("size", I32),
			cursor = b.local("cursor", I32), result = b.local("result", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalSet(size),
			LocalGet(2), I32Const(0), I32LtS, LocalGet(size), LocalGet(1), I32LtS, I32Or, If(null), LocalGet(0), I32Const(0), Call(newLike), Return, End,
			LocalGet(1), I32Const(0), I32LtS, If(null), LocalGet(1), LocalGet(size), I32Add, LocalSet(1),
			LocalGet(1), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(1), End, End,
			LocalGet(size), LocalGet(1), I32Sub, LocalGet(2), I32LtS, If(null), LocalGet(size), LocalGet(1), I32Sub, LocalSet(2), End,
			LocalGet(0), LocalGet(2), Call(newLike), LocalSet(result), Block(null), Loop(null), LocalGet(cursor), LocalGet(2), I32Eq, BrIf(1),
			LocalGet(result), LocalGet(cursor), LocalGet(0), LocalGet(1), LocalGet(cursor), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			I32Const(0), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(size), LocalGet(1), I32Sub, LocalGet(2), I32Sub, I32Eq, BrIf(1),
			LocalGet(0), LocalGet(1), LocalGet(cursor), I32Add, LocalGet(0), LocalGet(1), LocalGet(2), I32Add, LocalGet(cursor), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			LocalGet(0), LocalGet(size), LocalGet(2), I32Sub, Call(resize), LocalGet(result), Return]);
		return b.finish();
	}

	static function removeAt(native:IrNative, move:Int, resize:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || move < 0 || resize < 0) throw "Invalid Wasm32 value-array removal";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[]}), size = b.local("size", I32), cursor = b.local("cursor", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalTee(size), LocalGet(1), I32LeS, I32Or,
			LocalGet(1), I32Const(0), I32LtS, I32Or, If(null)]); WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(1), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(size), I32Const(1), I32Sub, I32Eq, BrIf(1),
			LocalGet(0), LocalGet(cursor), LocalGet(0), LocalGet(cursor), I32Const(1), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			LocalGet(0), LocalGet(size), I32Const(1), I32Sub, Call(resize), Return]);
		return b.finish();
	}

	static function clearElement(native:IrNative):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2) throw "Invalid Wasm32 value-array clear";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[]}), address = b.local("validity-address", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(1), I32Const(0), I32LtS, I32Or, LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), LocalGet(1), I32LeS, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), LocalGet(1),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I32Const(8), I32DivS, I32Mul, I32Add, I32Const(0),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET), I32Const(8), I32DivS, MemoryFill,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), If(null),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET), LocalGet(1),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Mul, I32Const(4), I32Mul, I32Add, I32Const(0),
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET), I32Const(4), I32Mul, MemoryFill, End,
			LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null)]);
		appendValidityAddress(b);
		b.emitAll([LocalTee(address), LocalGet(address), I32Load8U(0), I32Const(1), LocalGet(1), I32Const(7), I32And, I32Shl,
			I32Const(-1), I32Xor, I32And, I32Store8(0), End, Return]);
		return b.finish();
	}

	static function ensure(native:IrNative, allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
		if (native.arguments.length != 2 || allocator < 0) throw "Invalid Wasm32 value-array growth";
		var b = new WasmFunctionBuilder(native.name, {parameters:[I32,I32], results:[]}), oldCapacity = b.local("old-capacity", I32),
			capacity = b.local("capacity", I32), oldPayload = b.local("old-payload", I32), payload = b.local("payload", I32),
			scalarBytes = b.local("scalar-bytes", I32), refBytes = b.local("reference-bytes", I32), total = b.local("checked-size", I64),
			scalar = b.local("new-scalar", I32), references = b.local("new-references", I32);
		b.emitAll([LocalGet(0), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz,
			LocalGet(1), I32Const(0), I32LtS, I32Or, LocalGet(1), I32Const(0x7fffffff), I32Eq, I32Or, If(null)]);
		WasmLinearRuntime.runtimeFailure(b); b.emitAll([End, LocalGet(1), LocalGet(0), I32Load(WasmLayout.ARRAY_LENGTH_OFFSET), I32LtS, If(null), Return, End,
			LocalGet(0), I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET), LocalSet(oldCapacity), LocalGet(1), LocalGet(oldCapacity), I32LtS, If(null),
			LocalGet(0), LocalGet(1), I32Const(1), I32Add, I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)]);
		b.emitAll(syncForwardLength()); b.emitAll([Return, End,
			LocalGet(oldCapacity), I64ExtendI32U, LocalGet(oldCapacity), I32Const(2), I32DivS, I64ExtendI32U, I64Add, LocalSet(total),
			LocalGet(total), I64Const(0x7fffffff), I64LeS, I32Eqz, If(null), LocalGet(1), I32Const(1), I32Add, LocalSet(capacity), Else,
			LocalGet(total), I32WrapI64, LocalGet(1), I32Const(1), I32Add, I32LeS, If(null), LocalGet(1), I32Const(1), I32Add,
			LocalSet(capacity), Else, LocalGet(total), I32WrapI64, LocalSet(capacity), End, End]);
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
			LocalGet(0), LocalGet(capacity), I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(0), LocalGet(1), I32Const(1), I32Add, I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)]);
		b.emitAll(syncForwardLength()); b.emit(Return);
		return b.finish();
	}

	static function allocate(module:compiler.backend.wasm.WasmModule.WasmModule, native:IrNative, allocator:Int):compiler.backend.wasm.WasmModule.WasmFunction {
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

	static function appendValidityAddress(builder:WasmFunctionBuilder, index:Int = 1, array:Int = 0):Void {
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
