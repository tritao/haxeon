package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrTypeCodec;

/** Scalar component boundary for nonescaping nullable struct elements. */
class IrValueArrayOptionalComponents {
	final element:IrType;
	final wrapper:IrType;
	final helpers:IrValueArraySlotHelpers;
	final slots:Array<compiler.ir.IrInlineValueLayout.IrInlineValueSlot>;
	final bridge:IrValueArrayBridge;
	final suffix:String;

	public function new(objects:IrObjectTable, element:IrType, helpers:IrValueArraySlotHelpers) {
		var name = switch element { case Nullable(Obj(value)): value; default: throw "Expected a nullable struct element"; };
		this.element = element;
		this.wrapper = Obj(IrOptionalScalarFlow.wrapperName(name));
		this.helpers = helpers;
		this.bridge = new IrValueArrayBridge(element, element, objects, helpers);
		this.slots = new IrInlineValueLayout(objects).slots(element);
		this.suffix = haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
	}

	public function getName():String return IrValueArrayElements.PREFIX + "optional-get:" + suffix;
	public function setName():String return IrValueArrayElements.PREFIX + "optional-set:" + suffix;
	public function pushName():String return IrValueArrayElements.PREFIX + "optional-push:" + suffix;
	public function insertName():String return IrValueArrayElements.PREFIX + "optional-insert:" + suffix;
	public function unshiftName():String return IrValueArrayElements.PREFIX + "optional-unshift:" + suffix;
	public function popName():String return IrValueArrayElements.PREFIX + "optional-pop:" + suffix;
	public function shiftName():String return IrValueArrayElements.PREFIX + "optional-shift:" + suffix;
	public function wrapperType():IrType return wrapper;

	public function functions():Array<IrFunction> {
		var arrayType:IrType = Array(element), get = new IrBuilder(), array = get.argument("array", arrayType),
			index = get.argument("index", I32), wrapperName = switch wrapper { case Obj(value): value; default: throw "Invalid optional wrapper"; };
		get.call(helpers.checker([], false), [array, index], Void);
		var result = get.newObject(wrapperName);
		for (slotIndex in 0...slots.length) {
			var slot = slots[slotIndex], value = switch slot.type {
				case Nullable(I32 | I64 | F32 | F64 | Bool): bridge.readValue(get, array, index, slot.type, slot.path);
				default: get.call(helpers.getter(helpers.slot(slot.path, slot.isPresence)), [array, index], slot.type);
			};
			get.fieldSet(result, "$slot" + slotIndex, value);
		}
		get.returnValue(result);
		var set = new IrBuilder(), target = set.argument("array", arrayType), position = set.argument("index", I32),
			value = set.argument("components", wrapper), values:Array<IrValue> = [];
		for (slotIndex in 0...slots.length) values.push(set.fieldGet(value, "$slot" + slotIndex, slots[slotIndex].type));
		set.call("__value_array_ensure", [target, position], Void);
		// Write payloads first, then flags from deepest to shallowest. A false flag clears every descendant slot.
		for (slotIndex in 0...slots.length) if (!slots[slotIndex].isPresence) {
			var slot = slots[slotIndex];
			switch slot.type {
				case Nullable(I32 | I64 | F32 | F64 | Bool): bridge.writeValue(set, target, position, values[slotIndex], slot.type, slot.path);
				default: set.call(helpers.setter(helpers.slot(slot.path)), [target, position, values[slotIndex]], Void);
			}
		}
		var presence = [for (slotIndex in 0...slots.length) if (slots[slotIndex].isPresence) slotIndex];
		presence.sort((left, right) -> slots[right].path.length - slots[left].path.length);
		for (slotIndex in presence)
			set.call(helpers.setter(helpers.slot(slots[slotIndex].path, true)), [target, position, values[slotIndex]], Void);
		set.call("__value_array_mark", [target, position], Void);
		set.returnValue(set.constVoid());
		var push = new IrBuilder(), pushArray = push.argument("array", arrayType), pushValue = push.argument("components", wrapper),
			length = new IrValue(1000000, "$array-length", I32);
		push.currentBlock().instructions.push(new Located(ArraySize(length, pushArray), SourceProvenance.generated("optional-array-push")));
		push.call(setName(), [pushArray, length, pushValue], Void);
		push.returnValue(push.add(length, push.constInt(1)));
		var insert = new IrBuilder(), insertArray = insert.argument("array", arrayType), insertPosition = insert.argument("position", I32),
			insertValue = insert.argument("components", wrapper), inserted = insert.call("__value_array_insert_empty", [insertArray, insertPosition], I32);
		insert.call(setName(), [insertArray, inserted, insertValue], Void);
		insert.returnValue(insert.constVoid());
		var unshift = new IrBuilder(), unshiftArray = unshift.argument("array", arrayType), unshiftValue = unshift.argument("components", wrapper),
			unshiftLength = new IrValue(1000000, "$array-length", I32);
		unshift.call(insertName(), [unshiftArray, unshift.constInt(0), unshiftValue], Void);
		unshift.currentBlock().instructions.push(new Located(ArraySize(unshiftLength, unshiftArray), SourceProvenance.generated("optional-array-unshift")));
		unshift.returnValue(unshiftLength);
		var pop = new IrBuilder(), popArray = pop.argument("array", arrayType), popLength = new IrValue(1000000, "$array-length", I32);
		pop.currentBlock().instructions.push(new Located(ArraySize(popLength, popArray), SourceProvenance.generated("optional-array-pop")));
		var popIndex = pop.sub(popLength, pop.constInt(1)), popValue = pop.call(getName(), [popArray, popIndex], wrapper);
		pop.call("__value_array_remove_at", [popArray, popIndex], Void);
		pop.returnValue(popValue);
		var shift = new IrBuilder(), shiftArray = shift.argument("array", arrayType), shiftIndex = shift.constInt(0),
			shiftValue = shift.call(getName(), [shiftArray, shiftIndex], wrapper);
		shift.call("__value_array_remove_at", [shiftArray, shiftIndex], Void);
		shift.returnValue(shiftValue);
		return [new IrFunction(getName(), get.arguments, wrapper, get.blocks, ValueArrayElement), new IrFunction(setName(), set.arguments, Void, set.blocks, ValueArrayElement),
			new IrFunction(pushName(), push.arguments, I32, push.blocks, ValueArrayElement), new IrFunction(insertName(), insert.arguments, Void, insert.blocks, ValueArrayElement),
			new IrFunction(unshiftName(), unshift.arguments, I32, unshift.blocks, ValueArrayElement), new IrFunction(popName(), pop.arguments, wrapper, pop.blocks, ValueArrayElement),
			new IrFunction(shiftName(), shift.arguments, wrapper, shift.blocks, ValueArrayElement)];
	}
}
