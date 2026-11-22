package compiler.ir.passes.enums;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.passes.values.IrValueLaneReference;

/** Traced enum payload slots carry references without materializing Dynamic boxes. */
class IrInlineEnumReferenceAccess {
	public static function write(builder:IrBuilder, owner:IrValue, index:Int, value:IrValue):Void {
		if (IrValueLaneReference.isCarrier(value.type)) {
			builder.fieldSet(owner, 'reference$index', value);
			return;
		}
		if (!IrValueLaneReference.canCarry(value.type))
			throw new InternalError('Cannot store ${value.type} in an enum reference slot');
		var carrier = builder.call(IrValueLaneReference.PACK, [value], IrValueLaneReference.type());
		builder.fieldSet(owner, 'reference$index', carrier);
	}

	public static function read(builder:IrBuilder, owner:IrValue, index:Int, type:IrType):IrValue {
		if (IrValueLaneReference.isCarrier(type)) return builder.fieldGet(owner, 'reference$index', type);
		if (!IrValueLaneReference.canCarry(type))
			throw new InternalError('Cannot load $type from an enum reference slot');
		var carrier = builder.fieldGet(owner, 'reference$index', IrValueLaneReference.type());
		return builder.call(IrValueLaneReference.UNPACK, [carrier], type);
	}
}
