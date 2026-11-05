package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.gc.WasmGcValueArrayAccessors.WasmGcValueArrayScalarAccess;

/** Word operations for typed scalar places and genuinely untyped native accesses. */
class WasmGcScalarArrayAccess {
	public static function build(plan:WasmGcTypePlan, native:IrNative, throws:Bool, spec:Null<WasmGcValueArrayScalarAccess>):WasmFunction {
		var symbol = native.symbol, clear = symbol == "__value_array_clear_scalar", write = clear || StringTools.startsWith(symbol, "__value_array_write_"),
			suffix = clear ? "clear" : symbol.substr(write ? "__value_array_write_".length : "__value_array_read_".length),
			integer = suffix == "i32" || suffix == "i64", variableWidth = integer || suffix == "ptr" || suffix == "type" || clear,
			expected = spec != null ? 2 + (write && !clear ? 1 : 0) : 3 + (variableWidth ? 1 : 0) + (write && !clear ? 1 : 0) + (!write && integer ? 1 : 0);
		if (native.arguments.length != expected) throw 'Invalid Wasm GC scalar access: ${native.name}';
		var b = new WasmFunctionBuilder(native.name, plan.wasmFunctionType(native.arguments, native.result)), w = plan.valueArrayWrapperTypeIndex,
			wrapper = b.local("wrapper", Ref({nullable:true, heap:Type(w)})), width = b.local("width", I32), bits = b.local("bits", I64);
		b.emitAll([LocalGet(0), RefIsNull, If(null)]); fail(b, throws); b.emitAll([End,
			LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalSet(wrapper),
			LocalGet(1), I32Const(0), I32LtS, LocalGet(wrapper), StructGet(w, WasmGcTypePlan.arrayLengthFieldIndex()), LocalGet(1), I32LeS, I32Or]);
		if (spec == null) {
			b.emitAll([LocalGet(2), I32Const(0), I32LtS, I32Or, LocalGet(2), I32Const(7), I32And, I32Or]);
			b.emit(variableWidth ? LocalGet(3) : I32Const(suffix == "bool" ? 8 : suffix == "f32" || suffix == "callback" ? 32 : 64));
			b.emit(LocalSet(width));
			b.emitAll([LocalGet(width), I32Const(8), I32Eq, LocalGet(width), I32Const(16), I32Eq, I32Or,
				LocalGet(width), I32Const(32), I32Eq, I32Or, LocalGet(width), I32Const(64), I32Eq, I32Or, I32Eqz, I32Or,
				LocalGet(2), I64ExtendI32U, LocalGet(width), I64ExtendI32U, I64Add,
				LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I64ExtendI32U, I64LeS, I32Eqz, I32Or]);
			if (suffix == "i32") b.emitAll([LocalGet(width), I32Const(32), I32LeS, I32Eqz, I32Or]);
			if (suffix == "ptr" || suffix == "type") b.emitAll([LocalGet(width), I32Const(32), I32Eq, I32Eqz, I32Or]);
		} else b.emitAll([I32Const(spec.widthBits), LocalSet(width)]);
		b.emit(If(null)); fail(b, throws); b.emit(End);
		if (write && !clear) {
			b.emit(LocalGet(spec != null ? 2 : variableWidth ? 4 : 3));
			b.emitAll(switch suffix {
				case "i32", "bool", "ptr", "type", "callback": [I64ExtendI32U];
				case "i64": [];
				case "f32": [F32DemoteF64, I32ReinterpretF32, I64ExtendI32U];
				case "f64": [I64ReinterpretF64];
				default: throw 'Invalid scalar write $suffix';
			});
			b.emit(LocalSet(bits));
		}
		if (spec == null) b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD), I32Const(32), I32Eq, If(null)]);
		for (wordBits in (spec == null ? [32, 64] : [spec.wordBits])) {
			var lane = wordBits == 32 ? plan.valueArrayI32LaneTypeIndex : plan.valueArrayI64LaneTypeIndex,
				data = b.local('lane-$wordBits', Ref({nullable:true, heap:Type(lane)}));
			b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane)}), LocalSet(data)]);
			if (!write) initialized(b, w, wrapper, lane, data, wordBits, spec, throws);
			if (spec == null) dynamicAccess(b, w, wrapper, lane, data, wordBits, width, bits, write);
			else typedAccess(b, lane, data, spec, bits, write);
			if (spec == null && wordBits == 32) b.emit(Else);
		}
		if (spec == null) b.emit(End);
		if (!write) {
			if (integer && (spec == null || spec.signed)) {
				if (spec == null) b.emitAll([LocalGet(4), If(null)]);
				b.emitAll([LocalGet(bits), I64Const(64), LocalGet(width), I64ExtendI32U, I64Sub, I64Shl,
					I64Const(64), LocalGet(width), I64ExtendI32U, I64Sub, I64ShrS, LocalSet(bits)]);
				if (spec == null) b.emit(End);
			}
			b.emit(LocalGet(bits));
			b.emitAll(switch suffix {
				case "i32", "ptr", "type", "callback": [I32WrapI64];
				case "bool": [I64Eqz, I32Eqz];
				case "i64": [];
				case "f32": [I32WrapI64, F32ReinterpretI32, F64PromoteF32];
				case "f64": [F64ReinterpretI64];
				default: throw 'Invalid scalar read $suffix';
			});
		}
		b.emit(Return); return b.finish();
	}

	static function fail(b:WasmFunctionBuilder, throws:Bool):Void b.emitAll(WasmGcValueArrays.failure(throws));
	static function logBits(bits:Int):Int return bits == 32 ? 5 : 6;
	static function mask(bits:Int):Array<WasmInstruction> return bits == 64 ? [I64Const(-1)] :
		bits == 32 ? [I64Const(-1), I64Const(32), I64ShrU] : [I64Const((1 << bits) - 1)];

	static function load(b:WasmFunctionBuilder, lane:Int, data:Int, index:Int, wordBits:Int, next:Bool = false):Void {
		b.emitAll([LocalGet(data), LocalGet(index)]);
		if (next) b.emitAll([I32Const(1), I32Add]);
		b.emit(ArrayGet(lane)); if (wordBits == 32) b.emit(I64ExtendI32U);
	}

	static function initialized(b:WasmFunctionBuilder, w:Int, wrapper:Int, lane:Int, data:Int, wordBits:Int,
			spec:Null<WasmGcValueArrayScalarAccess>, throws:Bool):Void {
		if (spec != null && !spec.hasValidity) return;
		if (spec == null) b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD), If(null)]);
		b.emitAll([LocalGet(data), LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD), I64ExtendI32U]);
		if (spec == null) b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I64ExtendI32U]);
		else b.emit(I64Const(spec.strideBits));
		b.emitAll([I64Mul, I64Const(wordBits - 1), I64Add, I64Const(logBits(wordBits)), I64ShrU,
			LocalGet(1), I32Const(logBits(wordBits)), I32ShrU, I64ExtendI32U, I64Add, I32WrapI64, ArrayGet(lane)]);
		if (wordBits == 32) b.emit(I64ExtendI32U);
		b.emitAll([LocalGet(1), I32Const(wordBits - 1), I32And, I64ExtendI32U, I64ShrU, I64Const(1), I64And, I64Eqz, If(null)]);
		fail(b, throws); b.emit(End); if (spec == null) b.emit(End);
	}

	/** A typed leaf spans at most two words; aligned full words need no read/modify/write. */
	static function typedAccess(b:WasmFunctionBuilder, lane:Int, data:Int, spec:WasmGcValueArrayScalarAccess, bits:Int, write:Bool):Void {
		var wordBits = spec.wordBits, index = b.local("word-index", I32), shift = b.local("bit-shift", I64),
			fixedShift = spec.strideBits % wordBits == 0 ? spec.offsetBits % wordBits : -1;
		if (fixedShift >= 0) b.emitAll([LocalGet(1), I32Const(Std.int(spec.strideBits / wordBits)), I32Mul,
			I32Const(Std.int(spec.offsetBits / wordBits)), I32Add, LocalSet(index), I64Const(fixedShift), LocalSet(shift)]);
		else {
			var address = b.local("bit-address", I64);
			b.emitAll([LocalGet(1), I64ExtendI32U, I64Const(spec.strideBits), I64Mul, I64Const(spec.offsetBits), I64Add, LocalSet(address),
				LocalGet(address), I64Const(logBits(wordBits)), I64ShrU, I32WrapI64, LocalSet(index),
				LocalGet(address), I64Const(wordBits - 1), I64And, LocalSet(shift)]);
		}
		var alignment = wordBits, step = spec.strideBits;
		while (step != 0) { var next = alignment % step; alignment = step; step = next; }
		var maximumShift = wordBits - alignment + spec.offsetBits % alignment;
		span(b, lane, data, wordBits, spec.widthBits, index, shift, bits, write, fixedShift, maximumShift + spec.widthBits > wordBits);
	}

	/** Read or update a scalar span in at most two cached lane words. */
	public static function span(b:WasmFunctionBuilder, lane:Int, data:Int, wordBits:Int, width:Int, index:Int, shift:Int,
			bits:Int, write:Bool, fixedShift:Int = -1, mayCross:Bool = true):Void {
		var crosses = mayCross && (fixedShift < 0 || fixedShift + width > wordBits);
		if (write && fixedShift == 0 && width == wordBits) {
			b.emitAll([LocalGet(data), LocalGet(index), LocalGet(bits)]); if (wordBits == 32) b.emit(I32WrapI64); b.emit(ArraySet(lane)); return;
		}
		if (write) {
			if (width < 64) b.emitAll([LocalGet(bits)].concat(mask(width)).concat([I64And, LocalSet(bits)]));
			b.emitAll([LocalGet(data), LocalGet(index)]); load(b, lane, data, index, wordBits);
			b.emitAll(mask(width).concat([LocalGet(shift), I64Shl, I64Const(-1), I64Xor, I64And,
				LocalGet(bits), LocalGet(shift), I64Shl, I64Or]));
			if (wordBits == 32) b.emit(I32WrapI64); b.emit(ArraySet(lane));
		} else {
			load(b, lane, data, index, wordBits);
			if (fixedShift != 0) b.emitAll([LocalGet(shift), I64ShrU]);
			b.emit(LocalSet(bits));
		}
		if (crosses) {
			if (fixedShift < 0) b.emitAll([LocalGet(shift), I64Const(wordBits - width), I64LeS, I32Eqz, If(null)]);
			if (write) {
				var remaining = b.local('span-remaining-${b.locals.length}', I64);
				b.emitAll([I64Const(wordBits), LocalGet(shift), I64Sub, LocalSet(remaining), LocalGet(data), LocalGet(index), I32Const(1), I32Add]);
				load(b, lane, data, index, wordBits, true);
				b.emitAll(mask(width).concat([LocalGet(remaining), I64ShrU, I64Const(-1), I64Xor, I64And,
					LocalGet(bits), LocalGet(remaining), I64ShrU, I64Or]));
				if (wordBits == 32) b.emit(I32WrapI64); b.emit(ArraySet(lane));
			} else {
				b.emit(LocalGet(bits)); load(b, lane, data, index, wordBits, true);
				b.emitAll([I64Const(wordBits), LocalGet(shift), I64Sub, I64Shl, I64Or, LocalSet(bits)]);
			}
			if (fixedShift < 0) b.emit(End);
		}
		if (!write && width < 64) b.emitAll([LocalGet(bits)].concat(mask(width)).concat([I64And, LocalSet(bits)]));
	}

	/** Unknown native metadata is processed one word fragment at a time, never byte by byte. */
	static function dynamicAccess(b:WasmFunctionBuilder, w:Int, wrapper:Int, lane:Int, data:Int, wordBits:Int, width:Int, bits:Int, write:Bool):Void {
		var address = b.local('address-$wordBits', I64), cursor = b.local('cursor-$wordBits', I32), index = b.local('index-$wordBits', I32),
			shift = b.local('shift-$wordBits', I64), chunk = b.local('chunk-$wordBits', I32), fieldMask = b.local('mask-$wordBits', I64);
		b.emitAll([LocalGet(1), I64ExtendI32U, LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I64ExtendI32U,
			I64Mul, LocalGet(2), I64ExtendI32U, I64Add, LocalSet(address), Block(null), Loop(null), LocalGet(cursor), LocalGet(width), I32Eq, BrIf(1),
			LocalGet(address), LocalGet(cursor), I64ExtendI32U, I64Add, I64Const(logBits(wordBits)), I64ShrU, I32WrapI64, LocalSet(index),
			LocalGet(address), LocalGet(cursor), I64ExtendI32U, I64Add, I64Const(wordBits - 1), I64And, LocalSet(shift),
			LocalGet(width), LocalGet(cursor), I32Sub, LocalSet(chunk), LocalGet(chunk), I32Const(wordBits), LocalGet(shift), I32WrapI64, I32Sub,
			I32LeS, I32Eqz, If(null), I32Const(wordBits), LocalGet(shift), I32WrapI64, I32Sub, LocalSet(chunk), End,
			I64Const(-1), I64Const(64), LocalGet(chunk), I64ExtendI32U, I64Sub, I64ShrU, LocalSet(fieldMask)]);
		if (write) {
			b.emitAll([LocalGet(data), LocalGet(index)]); load(b, lane, data, index, wordBits);
			b.emitAll([LocalGet(fieldMask), LocalGet(shift), I64Shl, I64Const(-1), I64Xor, I64And,
				LocalGet(bits), LocalGet(cursor), I64ExtendI32U, I64ShrU, LocalGet(fieldMask), I64And, LocalGet(shift), I64Shl, I64Or]);
			if (wordBits == 32) b.emit(I32WrapI64); b.emit(ArraySet(lane));
		} else {
			b.emit(LocalGet(bits)); load(b, lane, data, index, wordBits);
			b.emitAll([LocalGet(shift), I64ShrU, LocalGet(fieldMask), I64And, LocalGet(cursor), I64ExtendI32U, I64Shl, I64Or, LocalSet(bits)]);
		}
		b.emitAll([LocalGet(cursor), LocalGet(chunk), I32Add, LocalSet(cursor), Br(0), End, End]);
	}
}
