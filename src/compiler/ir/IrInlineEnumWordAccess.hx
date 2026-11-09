package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneSlot;

/** Packs and unpacks scalar leaves in an inline enum's overlapping payload words. */
class IrInlineEnumWordAccess {
	final bits:Int;
	final wordType:IrType;

	public function new(bits:Int) {
		if (bits != 32 && bits != 64) throw 'Invalid enum payload word size $bits';
		this.bits = bits;
		this.wordType = bits == 64 ? I64 : I32;
	}

	/** Bit conversions are native on HashLink and lowered to Wasm reinterpret instructions. */
	public static function natives():Array<IrNative> return [
		{name: "__f32_to_i32_bits", library: "haxeon_runtime", symbol: "__f32_to_i32_bits", arguments: [F32], result: I32},
		{name: "__i32_to_f32_bits", library: "haxeon_runtime", symbol: "__i32_to_f32_bits", arguments: [I32], result: F32},
		{name: "__f64_to_i64_bits", library: "haxeon_runtime", symbol: "__f64_to_i64_bits", arguments: [F64], result: I64},
		{name: "__i64_to_f64_bits", library: "haxeon_runtime", symbol: "__i64_to_f64_bits", arguments: [I64], result: F64},
		{name: "haxe.Int64.toInt", library: "haxeon_runtime", symbol: "__int64_to_int", arguments: [I64], result: I32}
	];

	/** The caller initializes the destination's words before storing any payload leaves. */
	public function write(builder:IrBuilder, owner:IrValue, slot:IrValueLaneSlot, value:IrValue):Void {
		if (slot.isReference) throw "Reference slots are not scalar words";
		if (slot.bitWidth > bits) throw "A scalar payload must fit its enum word width";
		var encoded = encode(builder, value), first = Std.int(Math.min(slot.bitWidth, bits - slot.bitOffset));
		writePart(builder, owner, slot.index, slot.bitOffset, first, encoded);
		var remaining = slot.bitWidth - first;
		if (remaining > 0) writePart(builder, owner, slot.index + 1, 0, remaining,
			builder.unsignedShiftRight(encoded, builder.constInt(first)));
	}

	public function read(builder:IrBuilder, owner:IrValue, slot:IrValueLaneSlot):IrValue {
		if (slot.isReference) throw "Reference slots are not scalar words";
		if (slot.bitWidth > bits) throw "A scalar payload must fit its enum word width";
		var first = Std.int(Math.min(slot.bitWidth, bits - slot.bitOffset)),
			value = readPart(builder, owner, slot.index, slot.bitOffset, first), remaining = slot.bitWidth - first;
		if (remaining > 0)
			value = builder.bitOr(value, builder.shiftLeft(readPart(builder, owner, slot.index + 1, 0, remaining), builder.constInt(first)));
		if (slot.signed && slot.bitWidth < bits) {
			var shift = builder.constInt(bits - slot.bitWidth);
			value = builder.shiftRight(builder.shiftLeft(value, shift), shift);
		}
		return decode(builder, value, slot.type);
	}

	function writePart(builder:IrBuilder, owner:IrValue, index:Int, offset:Int, width:Int, value:IrValue):Void {
		if (offset == 0 && width == bits) {
			builder.fieldSet(owner, 'scalar$index', value);
			return;
		}
		var mask = maskFor(builder, width), shiftedMask = offset == 0 ? mask : builder.shiftLeft(mask, builder.constInt(offset)),
			part = builder.bitAnd(value, mask), shifted = offset == 0 ? part : builder.shiftLeft(part, builder.constInt(offset)),
			old = builder.fieldGet(owner, 'scalar$index', wordType),
			clear = builder.bitXor(shiftedMask, builder.constInt(-1, wordType));
		builder.fieldSet(owner, 'scalar$index', builder.bitOr(builder.bitAnd(old, clear), shifted));
	}

	function readPart(builder:IrBuilder, owner:IrValue, index:Int, offset:Int, width:Int):IrValue {
		var word = builder.fieldGet(owner, 'scalar$index', wordType);
		if (offset != 0) word = builder.unsignedShiftRight(word, builder.constInt(offset));
		return width == bits ? word : builder.bitAnd(word, maskFor(builder, width));
	}

	function maskFor(builder:IrBuilder, width:Int):IrValue {
		if (width <= 0 || width > bits) throw 'Invalid enum payload bit width $width';
		var all = builder.constInt(-1, wordType);
		return width == bits ? all : builder.unsignedShiftRight(all, builder.constInt(bits - width));
	}

	function encode(builder:IrBuilder, value:IrValue):IrValue return switch value.type {
		case EnumTag(_):
			var encoded = builder.call(IrScalarWordBits.PACK, [value], I32);
			bits == 32 ? encoded : builder.intToInt64(encoded);
		case I32: bits == 32 ? value : builder.intToInt64(value);
		case RawPtr, TypeRef, Abstract("native_callback"):
			var encoded = builder.call(IrScalarWordBits.PACK, [value], I64);
			bits == 64 ? encoded : builder.call("haxe.Int64.toInt", [encoded], I32);
		case I64 if (bits == 64): value;
		case F64 if (bits == 64): builder.call("__f64_to_i64_bits", [value], I64);
		case F32: var encoded = builder.call("__f32_to_i32_bits", [value], I32); bits == 32 ? encoded : builder.intToInt64(encoded);
		case Bool:
			var yes = builder.createBlock(), no = builder.createBlock(), done = builder.createBlock();
			builder.branch(value, yes, no);
			builder.select(yes); var one = builder.constInt(1, wordType); builder.jump(done);
			builder.select(no); var zero = builder.constInt(0, wordType); builder.jump(done);
			builder.select(done); builder.phi(wordType, [{block: yes.id, value: one}, {block: no.id, value: zero}]);
		default: throw 'Unsupported enum scalar payload ${value.type}';
	};

	function decode(builder:IrBuilder, value:IrValue, type:IrType):IrValue return switch type {
		case EnumTag(_): builder.call(IrScalarWordBits.UNPACK,
			[bits == 32 ? value : builder.call("haxe.Int64.toInt", [value], I32)], type);
		case I32: bits == 32 ? value : builder.call("haxe.Int64.toInt", [value], I32);
		case RawPtr, TypeRef, Abstract("native_callback"):
			builder.call(IrScalarWordBits.UNPACK, [bits == 64 ? value : builder.intToInt64(value)], type);
		case I64 if (bits == 64): value;
		case F64 if (bits == 64): builder.call("__i64_to_f64_bits", [value], F64);
		case F32: builder.call("__i32_to_f32_bits", [bits == 32 ? value : builder.call("haxe.Int64.toInt", [value], I32)], F32);
		case Bool: builder.equal(builder.equal(value, builder.constInt(0, wordType)), builder.constBool(false));
		default: throw 'Unsupported enum scalar payload $type';
	};
}
