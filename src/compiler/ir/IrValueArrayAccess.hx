package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneSlot;

/** Emit typed access to one leaf of an inline array element without materializing the containing value. */
class IrValueArrayAccess {
	final wordBits:Int;
	final declarations:Map<String, IrNative> = [];

	public function new(wordBits:Int) {
		if (wordBits != 32 && wordBits != 64) throw 'Unsupported value lane word width $wordBits';
		this.wordBits = wordBits;
	}

	/** The caller validates optional ancestors before reading their payload slots. */
	public function read(builder:IrBuilder, array:IrValue, index:IrValue, slot:IrValueLaneSlot):IrValue {
		var args = [array, index, builder.constInt(slot.isReference ? slot.index : scalarOffset(slot))];
		if (slot.isReference) {
			declare(IrValueLaneReference.READ, [Array(Dyn), I32, I32], IrValueLaneReference.type());
			var carrier = builder.call(IrValueLaneReference.READ, args, IrValueLaneReference.type());
			return builder.call(IrValueLaneReference.UNPACK, [carrier], slot.type);
		}
		var suffix = scalarSuffix(slot.type), name = '__value_array_read_$suffix';
		var types:Array<IrType> = [Array(Dyn), I32, I32];
		if (suffix == "i32" || suffix == "i64" || suffix == "ptr" || suffix == "type") {
			args.push(builder.constInt(slot.bitWidth)); types.push(I32);
		}
		if (suffix == "i32" || suffix == "i64") { args.push(builder.constBool(slot.signed)); types.push(Bool); }
		declare(name, types, slot.type);
		return builder.call(name, args, slot.type);
	}

	/** The caller grows the array before writing and marks the element initialized after all leaves are written. */
	public function write(builder:IrBuilder, array:IrValue, index:IrValue, slot:IrValueLaneSlot, value:IrValue):Void {
		if (!IrVerifier.sameType(value.type, slot.type)) throw 'Wrong value lane slot type: ${value.type}, expected ${slot.type}';
		var args = [array, index, builder.constInt(slot.isReference ? slot.index : scalarOffset(slot))];
		if (slot.isReference) {
			declare(IrValueLaneReference.WRITE, [Array(Dyn), I32, I32, IrValueLaneReference.type()], Void);
			args.push(builder.call(IrValueLaneReference.PACK, [value], IrValueLaneReference.type()));
			builder.call(IrValueLaneReference.WRITE, args, Void);
			return;
		}
		var suffix = scalarSuffix(slot.type), name = '__value_array_write_$suffix';
		var types:Array<IrType> = [Array(Dyn), I32, I32];
		if (suffix == "i32" || suffix == "i64" || suffix == "ptr" || suffix == "type") {
			args.push(builder.constInt(slot.bitWidth)); types.push(I32);
		}
		args.push(value); types.push(slot.type);
		declare(name, types, Void);
		builder.call(name, args, Void);
	}

	/** Clear one leaf without inventing a typed zero for pointers or runtime type handles. */
	public function clear(builder:IrBuilder, array:IrValue, index:IrValue, slot:IrValueLaneSlot):Void {
		var name = slot.isReference ? "__value_array_clear_ref" : "__value_array_clear_scalar";
		var args = [array, index, builder.constInt(slot.isReference ? slot.index : scalarOffset(slot))];
		var types:Array<IrType> = [Array(Dyn), I32, I32];
		if (!slot.isReference) { args.push(builder.constInt(slot.bitWidth)); types.push(I32); }
		declare(name, types, Void);
		builder.call(name, args, Void);
	}

	public function natives():Array<IrNative> {
		var names = [for (name in declarations.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) declarations.get(name)];
	}

	function scalarOffset(slot:IrValueLaneSlot):Int {
		var offset = slot.index * 1.0 * wordBits + slot.bitOffset;
		if (offset > 0x7fffffff) throw 'Value lane offset is too large';
		return Std.int(offset);
	}

	static function scalarSuffix(type:IrType):String return switch type {
		case I32: "i32";
		case I64: "i64";
		case Bool: "bool";
		case F32: "f32";
		case F64: "f64";
		case RawPtr: "ptr";
		case TypeRef: "type";
		case Abstract("native_callback"): "callback";
		default: throw 'Unsupported scalar value lane type $type';
	};

	function declare(name:String, arguments:Array<IrType>, result:IrType):Void {
		var previous = declarations.get(name);
		if (previous != null) {
			if (!IrVerifier.sameType(previous.result, result) || previous.arguments.length != arguments.length)
				throw 'Conflicting value lane native "$name"';
			for (i in 0...arguments.length) if (!IrVerifier.sameType(previous.arguments[i], arguments[i]))
				throw 'Conflicting value lane native "$name"';
			return;
		}
		declarations.set(name, {name: name, library: "haxeon_runtime", symbol: name, arguments: arguments, result: result});
	}
}
