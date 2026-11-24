package compiler.ir.passes.arrays;

import compiler.ir.passes.enums.IrInlineEnumStorage;
import compiler.ir.model.IrObjectTable;
import compiler.ir.passes.values.IrValueLaneLayout;
import compiler.core.InternalError;
import compiler.ir.model.Ir.IrEnum;
import compiler.ir.model.Ir.IrType;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneShape;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;

/** Array-specific storage around a value's scalar/reference lanes. */
@:nullSafety(Strict)
class IrValueArrayLayout {
	public final element:IrType;
	public final storage:IrType;
	public final lanes:IrValueLaneShape;
	/** Non-null struct arrays need to distinguish grown, unwritten slots from initialized values. */
	public final hasValidity:Bool;

	public function new(objects:IrObjectTable, element:IrType, pointerBits:Int, target:IrValueLaneTarget,
			?enums:Array<IrEnum>) {
		this.element = element;
		// An enum tag is its own storage; a struct, or an enum stored inline, names the value class it is stored as.
		var validity = false, stored = element, name:Null<String> = null;
		switch element {
			case EnumTag(_):
			case Obj(value):
				validity = true;
				name = value;
			case Nullable(Obj(value)):
				name = value;
			case Nullable(Enum(_)): throw new InternalError("Nullable enums must use their canonical Enum IR type");
			case Enum(value):
				var resolved = enums == null ? null : IrInlineEnumStorage.resolve(enums, objects, value);
				if (resolved == null) throw new InternalError('Enum "$value" has no inline storage');
				// Enum null is tag zero, not an additional optional wrapper or validity bit.
				stored = resolved;
				name = switch resolved {
					case Obj(record): record;
					default: throw new InternalError("Invalid enum value record");
				};
			default: throw new InternalError('A value array requires a struct element');
		}
		hasValidity = validity;
		storage = stored;
		if (name != null) {
			var object = objects.get(name);
			if (object == null || !object.isValue) throw new InternalError('Array element "$name" is not a struct');
		}
		lanes = new IrValueLaneLayout(objects, pointerBits, target).shape(stored);
	}

	/** Validity bits follow the payload in the same scalar lane; growth moves them when capacity changes. */
	public function validityWordOffset(capacity:Int):Int
		return IrValueLaneLayout.scalarStorageWords(lanes, capacity);

	public function scalarStorageWords(capacity:Int):Int {
		var payload = validityWordOffset(capacity);
		if (!hasValidity) return payload;
		var validity = Math.fceil(capacity * 1.0 / lanes.scalarWordBits), total = payload * 1.0 + validity;
		if (total > 0x7fffffff) throw new InternalError('Value array scalar lane is too large');
		return Std.int(total);
	}

	public function referenceStorageSlots(capacity:Int):Int
		return IrValueLaneLayout.referenceStorageSlots(lanes, capacity);
}
