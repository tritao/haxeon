package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Scalar storage ranges: whole words in the middle, byte accesses only at unaligned ends. */
class WasmGcScalarRange {
	public static function byteHelpers(module:WasmModule, plan:WasmGcTypePlan, write:Bool):Array<Int> {
		var result:Array<Int> = [];
		for (wordBits in [32, 64]) {
			var lane = wordBits == 32 ? plan.valueArrayI32LaneTypeIndex : plan.valueArrayI64LaneTypeIndex,
				parameters:Array<WasmValueType> = [Ref({nullable:true, heap:Type(lane)}), I64];
			if (write) parameters.push(I32);
			var b = new WasmFunctionBuilder('$$lane-storage-internal:${write ? "write" : "read"}-byte-$wordBits',
				{parameters:parameters, results:write ? [] : [I32]}), index = b.local("index", I32), shift = b.local("shift", I64);
			b.emitAll([LocalGet(1), I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64, LocalSet(index),
				LocalGet(1), I64Const(Std.int(wordBits / 8) - 1), I64And, I64Const(3), I64Shl, LocalSet(shift)]);
			if (write) b.emitAll([LocalGet(0), LocalGet(index)]);
			b.emitAll([LocalGet(0), LocalGet(index), ArrayGet(lane)]);
			if (wordBits == 32) b.emit(I64ExtendI32U);
			if (write) {
				b.emitAll([I64Const(255), LocalGet(shift), I64Shl, I64Const(-1), I64Xor, I64And,
					LocalGet(2), I64ExtendI32U, I64Const(255), I64And, LocalGet(shift), I64Shl, I64Or]);
				if (wordBits == 32) b.emit(I32WrapI64);
				b.emit(ArraySet(lane));
			} else b.emitAll([LocalGet(shift), I64ShrU, I64Const(255), I64And, I32WrapI64]);
			b.emit(Return); result.push(module.addFunction(b.finish()));
		}
		return result;
	}

	public static function emit(b:WasmFunctionBuilder, plan:WasmGcTypePlan, operation:String, reads:Array<Int>, writes:Array<Int>):Void {
		var copy = operation == "copy-scalars", swap = operation == "swap-scalars", w = plan.valueArrayWrapperTypeIndex,
			wrapper = b.local("scalar-wrapper", Ref({nullable:true, heap:Type(w)})), stride = b.local("stride-bytes", I64),
			start = b.local("target-byte", I64), source = b.local("source-byte", I64), count = b.local("bytes", I64),
			cursor = b.local("cursor", I64), bits = b.local("word", I64), temp = b.local("temporary-word", I64), byte = b.local("byte", I32);
		b.emitAll([LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalSet(wrapper),
			LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I64ExtendI32U, I64Const(3), I64ShrU,
			LocalTee(stride), I64Eqz, If(null), Return, End, LocalGet(1), I64ExtendI32U, LocalGet(stride), I64Mul, LocalSet(start),
			swap ? I64Const(1) : LocalGet(copy ? 4 : 2)]);
		if (!swap) b.emit(I64ExtendI32U);
		b.emitAll([LocalGet(stride), I64Mul, LocalTee(count), I64Eqz, If(null), Return, End]);
		if (copy || swap) b.emitAll([LocalGet(copy ? 3 : 2), I64ExtendI32U, LocalGet(stride), I64Mul, LocalSet(source)]);
		b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD), I32Const(32), I32Eq, If(null)]);
		for (wordBits in [32, 64]) {
			var lane = wordBits == 32 ? plan.valueArrayI32LaneTypeIndex : plan.valueArrayI64LaneTypeIndex, wordBytes = Std.int(wordBits / 8),
				to = b.local('target-lane-$wordBits', Ref({nullable:true, heap:Type(lane)})),
				from = copy ? b.local('source-lane-$wordBits', Ref({nullable:true, heap:Type(lane)})) : to,
				read = reads[wordBits == 32 ? 0 : 1], write = writes[wordBits == 32 ? 0 : 1];
			b.emitAll([LocalGet(wrapper), StructGet(w, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane)}), LocalSet(to)]);
			if (copy) b.emitAll([LocalGet(2), RefCast({nullable:false, heap:Type(w)}), StructGet(w, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable:false, heap:Type(lane)}), LocalSet(from)]);
			if (swap) {
				// The common aligned shape has direct word swaps, with no per-word alignment branch.
				b.emitAll([LocalGet(stride), I64Const(wordBytes - 1), I64And, I64Eqz, If(null)]);
				swapWords(b, lane, to, wordBits, start, source, count, cursor, bits, temp, true);
				b.emit(Else);
				swapWords(b, lane, to, wordBits, start, source, count, cursor, bits, temp, false);
				b.emit(End);
				tail(b, to, from, start, source, count, cursor, byte, read, write, false, true);
			} else {
				if (copy) {
					b.emitAll([LocalGet(start), LocalGet(source), I64Or, LocalGet(count), I64Or, I64Const(wordBytes - 1), I64And, I64Eqz, If(null),
						LocalGet(to), LocalGet(start), I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64,
						LocalGet(from), LocalGet(source), I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64,
						LocalGet(count), I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64, ArrayCopy(lane, lane), Return, End,
						LocalGet(0), LocalGet(2), RefEq, LocalGet(source), LocalGet(start), I64LtU, I32And, If(null), LocalGet(count), LocalSet(cursor)]);
					backward(b, lane, to, from, wordBits, start, source, cursor, bits, read, write);
					b.emitAll([Return, End]);
				}
				// Align the target before copying/filling the complete middle words.
				b.emitAll([Block(null), Loop(null), LocalGet(cursor), LocalGet(count), I64Eq, BrIf(1),
					LocalGet(start), LocalGet(cursor), I64Add, I64Const(wordBytes - 1), I64And, I64Eqz, BrIf(1)]);
				oneByte(b, to, from, start, source, cursor, read, write, copy);
				b.emitAll([LocalGet(cursor), I64Const(1), I64Add, LocalSet(cursor), Br(0), End, End]);
				if (copy) {
					b.emitAll([Block(null), Loop(null), LocalGet(cursor), I64Const(wordBytes), I64Add, LocalGet(count), I64LeS, I32Eqz, BrIf(1)]);
					wordAt(b, lane, from, wordBits, source, cursor, bits, false, false);
					wordAt(b, lane, to, wordBits, start, cursor, bits, true, true);
					b.emitAll([LocalGet(cursor), I64Const(wordBytes), I64Add, LocalSet(cursor), Br(0), End, End]);
				} else {
					var words = b.local('clear-words-$wordBits', I32);
					b.emitAll([LocalGet(count), LocalGet(cursor), I64Sub, I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64, LocalSet(words),
						LocalGet(to), LocalGet(start), LocalGet(cursor), I64Add, I64Const(wordBits == 32 ? 2 : 3), I64ShrU, I32WrapI64]);
					b.emit(wordBits == 32 ? I32Const(0) : I64Const(0));
					b.emitAll([LocalGet(words), ArrayFill(lane), LocalGet(cursor), LocalGet(words), I64ExtendI32U, I64Const(wordBytes), I64Mul, I64Add, LocalSet(cursor)]);
				}
				tail(b, to, from, start, source, count, cursor, byte, read, write, copy, false);
			}
			if (wordBits == 32) b.emit(Else);
		}
		b.emit(End);
	}

	static function oneByte(b:WasmFunctionBuilder, to:Int, from:Int, start:Int, source:Int, cursor:Int, read:Int, write:Int, copy:Bool):Void {
		b.emitAll([LocalGet(to), LocalGet(start), LocalGet(cursor), I64Add]);
		if (copy) b.emitAll([LocalGet(from), LocalGet(source), LocalGet(cursor), I64Add, Call(read)]); else b.emit(I32Const(0));
		b.emit(Call(write));
	}

	static function tail(b:WasmFunctionBuilder, to:Int, from:Int, start:Int, source:Int, count:Int, cursor:Int, byte:Int,
			read:Int, write:Int, copy:Bool, swap:Bool):Void {
		b.emitAll([Block(null), Loop(null), LocalGet(cursor), LocalGet(count), I64Eq, BrIf(1)]);
		if (swap) b.emitAll([LocalGet(to), LocalGet(start), LocalGet(cursor), I64Add, Call(read), LocalSet(byte)]);
		oneByte(b, to, from, start, source, cursor, read, write, copy || swap);
		if (swap) b.emitAll([LocalGet(from), LocalGet(source), LocalGet(cursor), I64Add, LocalGet(byte), Call(write)]);
		b.emitAll([LocalGet(cursor), I64Const(1), I64Add, LocalSet(cursor), Br(0), End, End]);
	}

	static function backward(b:WasmFunctionBuilder, lane:Int, to:Int, from:Int, wordBits:Int, start:Int, source:Int, cursor:Int,
			bits:Int, read:Int, write:Int):Void {
		var bytes = Std.int(wordBits / 8);
		b.emitAll([Block(null), Loop(null), LocalGet(cursor), I64Eqz, BrIf(1),
			LocalGet(start), LocalGet(cursor), I64Add, I64Const(bytes - 1), I64And, I64Eqz, BrIf(1),
			LocalGet(cursor), I64Const(1), I64Sub, LocalSet(cursor)]);
		oneByte(b, to, from, start, source, cursor, read, write, true);
		b.emitAll([Br(0), End, End, Block(null), Loop(null), LocalGet(cursor), I64Const(bytes), I64LtU, BrIf(1),
			LocalGet(cursor), I64Const(bytes), I64Sub, LocalSet(cursor)]);
		wordAt(b, lane, from, wordBits, source, cursor, bits, false, false);
		wordAt(b, lane, to, wordBits, start, cursor, bits, true, true);
		b.emitAll([Br(0), End, End, Block(null), Loop(null), LocalGet(cursor), I64Eqz, BrIf(1), LocalGet(cursor), I64Const(1), I64Sub, LocalSet(cursor)]);
		oneByte(b, to, from, start, source, cursor, read, write, true);
		b.emitAll([Br(0), End, End]);
	}

	static function swapWords(b:WasmFunctionBuilder, lane:Int, data:Int, wordBits:Int, start:Int, source:Int, count:Int, cursor:Int,
			bits:Int, temp:Int, aligned:Bool):Void {
		var bytes = Std.int(wordBits / 8);
		b.emitAll([Block(null), Loop(null), LocalGet(cursor), I64Const(bytes), I64Add, LocalGet(count), I64LeS, I32Eqz, BrIf(1)]);
		wordAt(b, lane, data, wordBits, start, cursor, temp, false, aligned);
		wordAt(b, lane, data, wordBits, source, cursor, bits, false, aligned);
		wordAt(b, lane, data, wordBits, start, cursor, bits, true, aligned);
		wordAt(b, lane, data, wordBits, source, cursor, temp, true, aligned);
		b.emitAll([LocalGet(cursor), I64Const(bytes), I64Add, LocalSet(cursor), Br(0), End, End]);
	}

	/** Reuse the scalar place kernel for an unaligned full word; no temporary backing array is needed. */
	static function wordAt(b:WasmFunctionBuilder, lane:Int, data:Int, wordBits:Int, start:Int, cursor:Int, bits:Int, write:Bool, aligned:Bool):Void {
		var id = b.locals.length, address = b.local('word-address-$id', I64), index = b.local('word-index-$id', I32), shift = b.local('word-shift-$id', I64);
		b.emitAll([LocalGet(start), LocalGet(cursor), I64Add, LocalSet(address), LocalGet(address), I64Const(wordBits == 32 ? 2 : 3), I64ShrU,
			I32WrapI64, LocalSet(index)]);
		if (aligned) b.emit(I64Const(0));
		else b.emitAll([LocalGet(address), I64Const(Std.int(wordBits / 8) - 1), I64And, I64Const(3), I64Shl]);
		b.emit(LocalSet(shift));
		WasmGcScalarArrayAccess.span(b, lane, data, wordBits, wordBits, index, shift, bits, write, aligned ? 0 : -1);
	}
}
