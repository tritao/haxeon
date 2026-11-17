package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import haxe.io.BytesInput;

/**
 * HashLink's binary encodings, read the way the VM reads them (vendor/hashlink/src/code.c): variable-length indices, operand
 * lists, type definitions and string tables. The module reader (HlModuleReader) and the patch reader (HlPatchReader) both
 * decode through these, so the two formats share one decoder; each adds only its own rules (a patch takes only the opcodes
 * this compiler emits, and no enum types).
 */
class HlBytecodeInput {
	/** The largest operand list a decoder accepts, as the VM's patch decoder bounds it, before reading any of it. */
	public static inline final MAX_OPERAND_COUNT = 0x1000000;

	/** A signed index: one byte below 0x80, else two or four with the sign in bit 5 of the first. */
	public static function index(input:BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var value = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? value : -value;
		}
		var value = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? value : -value;
	}

	/** An index that may not be negative; `format` names the encoding in the error (HLB, HLP). */
	public static function unsigned(input:BytesInput, format:String):Int {
		var value = index(input);
		if (value < 0)
			throw 'Negative unsigned $format index';
		return value;
	}

	/**
	 * The operands of `opcode`, `arity` giving their count as HlOpcodeSchema does: a fixed count, a switch (register, table
	 * size, one offset per entry, end offset) or a variable list (two operands, then a count and that many).
	 */
	public static function operands(input:BytesInput, opcode:Int, arity:Int, format:String):Array<Int>
		return switch arity {
			case HlOpcodeSchema.UNSUPPORTED: throw 'Unsupported $format opcode $opcode';
			case HlOpcodeSchema.SWITCH_ARITY:
				var register = index(input), count = operandCount(input, format), result = [register, count];
				for (_ in 0...count)
					result.push(index(input));
				result.push(index(input));
				result;
			case HlOpcodeSchema.VARIABLE_ARITY:
				var first = index(input),
					second = index(input),
					count = operandCount(input, format),
					result = [first, second, count];
				for (_ in 0...count)
					result.push(index(input));
				result;
			case count: [for (_ in 0...count) index(input)];
		}

	static function operandCount(input:BytesInput, format:String):Int {
		var count = unsigned(input, format);
		if (count > MAX_OPERAND_COUNT)
			throw "Invalid variable operand count";
		return count;
	}

	/**
	 * A type definition. `namedVirtuals`: a virtual type carries its nominal identity first (HLB 8, and every HLP). A structure
	 * is written with a base of -1, which it does not keep.
	 */
	public static function type(input:BytesInput, namedVirtuals:Bool, format:String):HlTypeDef {
		var tag = input.readByte();
		return switch tag {
			case HlType.Fun, HlType.Method:
				var count = input.readByte(), arguments = [for (_ in 0...count) index(input)], result = index(input);
				tag == HlType.Method ? Method(arguments, result) : Function(arguments, result);
			case HlType.Obj, HlType.Struct:
				var name = index(input),
					base = index(input),
					global = unsigned(input, format),
					fieldCount = unsigned(input, format),
					methodCount = unsigned(input, format),
					bindingCount = unsigned(input, format);
				var fields = [for (_ in 0...fieldCount) {
					name:index(input), type:index(input)
				}],
					methods = [for (_ in 0...methodCount)
					{
					name:index(input), functionIndex:index(input), prototype:index(input)
				}],
					bindings = [for (_ in 0...bindingCount * 2) index(input)];
				tag == HlType.Obj ? Object(name, base, global, fields, methods, bindings) : Structure(name, global,
					fields,
					methods, bindings);
			case HlType.Virtual:
				var name = namedVirtuals ? index(input) : -1;
				Virtual(name, [for (_ in 0...unsigned(input, format)) {
					name:index(input), type:index(input)
				}]);
			case HlType.Abstract:
				Abstract(index(input));
			case HlType.Enum:
				var name = index(input), global = unsigned(input, format);
				Enum(name, global, [for (_ in 0...unsigned(input, format))
					{
						name:index(input), params:[for (_ in 0...unsigned(input, format)) index(input)]
					}]);
			case HlType.EnumTag:
				var boxed = index(input);
				EnumTag(boxed, [for (_ in 0...unsigned(input, format)) unsigned(input, format)]);
			case HlType.Ref, HlType.Null, HlType.Packed:
				Parameterized(cast tag, index(input));
			default:
				Simple(cast tag);
		}
	}

	/** A string table as HLB writes it: the byte size of the NUL-terminated strings, the strings, then each one's length. */
	public static function strings(input:BytesInput, count:Int, format:String):Array<String> {
		var size = input.readInt32(), data = input.read(size), result:Array<String> = [], offset = 0;
		for (_ in 0...count) {
			var length = unsigned(input, format);
			if (offset + length >= size || data.get(offset + length) != 0)
				throw 'Invalid $format string table';
			result.push(data.getString(offset, length));
			offset += length + 1;
		}
		return result;
	}
}
