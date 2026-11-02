package compiler.ir;

import compiler.ir.Ir.IrType;
import compiler.ir.IrValueLaneLayout.IrValueLaneShape;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;

/** Array-specific storage around a value's scalar/reference lanes. */
class IrValueArrayLayout {
	public final lanes:IrValueLaneShape;
	/** Non-null struct arrays need to distinguish grown, unwritten slots from initialized values. */
	public final hasValidity:Bool;

	public function new(objects:IrObjectTable, element:IrType, pointerBits:Int, target:IrValueLaneTarget) {
		var name = switch element {
			case Obj(value): hasValidity = true; value;
			case Nullable(Obj(value)): hasValidity = false; value;
			default: throw 'A value array requires a struct element';
		};
		var object = objects.get(name);
		if (object == null || !object.isValue) throw 'Array element "$name" is not a struct';
		lanes = new IrValueLaneLayout(objects, pointerBits, target).shape(element);
	}

	/** Validity bits follow the payload in the same scalar lane; growth moves them when capacity changes. */
	public function validityWordOffset(capacity:Int):Int
		return IrValueLaneLayout.scalarStorageWords(lanes, capacity);

	public function scalarStorageWords(capacity:Int):Int {
		var payload = validityWordOffset(capacity);
		if (!hasValidity) return payload;
		var validity = Math.fceil(capacity * 1.0 / lanes.scalarWordBits), total = payload * 1.0 + validity;
		if (total > 0x7fffffff) throw 'Value array scalar lane is too large';
		return Std.int(total);
	}

	public function referenceStorageSlots(capacity:Int):Int
		return IrValueLaneLayout.referenceStorageSlots(lanes, capacity);
}
