package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrTypeCodec;

/** Typed element boundaries, lowered to scalar call components when the backend supports them. */
class IrValueArrayElements {
	public static inline final PREFIX = "$value-array:element:";
	final element:IrType;
	final helpers:IrValueArraySlotHelpers;
	final bridge:IrValueArrayBridge;
	final suffix:String;

	public function new(element:IrType, helpers:IrValueArraySlotHelpers, bridge:IrValueArrayBridge) {
		this.element = element;
		this.helpers = helpers;
		this.bridge = bridge;
		suffix = haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
	}

	public function getName():String return PREFIX + "get:" + suffix;
	public function setName():String return PREFIX + "set:" + suffix;
	public function pushName():String return PREFIX + "push:" + suffix;
	public function insertName():String return PREFIX + "insert:" + suffix;
	public function unshiftName():String return PREFIX + "unshift:" + suffix;
	public function popName():String return PREFIX + "pop:" + suffix;
	public function shiftName():String return PREFIX + "shift:" + suffix;
	public static function spliceNativeName(element:IrType):String
		return "$value-array:native-splice:" + haxe.crypto.Base64.encode(IrTypeCodec.encode(element));

	public function functions():Array<IrFunction> {
		var arrayType:IrType = Array(element), get = new IrBuilder(), array = get.argument("array", arrayType),
			index = get.argument("index", I32);
		get.call(helpers.checker([], false), [array, index], Void);
		get.returnValue(bridge.readValue(get, array, index, element, []));
		var set = new IrBuilder(), target = set.argument("array", arrayType), position = set.argument("index", I32),
			value = set.argument("value", element);
		set.call("__value_array_ensure", [target, position], Void);
		bridge.writeValue(set, target, position, value, element, []);
		set.call("__value_array_mark", [target, position], Void);
		set.returnValue(set.constVoid());
		var push = new IrBuilder(), pushArray = push.argument("array", arrayType), pushValue = push.argument("value", element),
			length = new IrValue(1000000, "$array-length", I32);
		push.currentBlock().instructions.push(new Located(ArraySize(length, pushArray), SourceProvenance.generated("value-array-push")));
		push.call(setName(), [pushArray, length, pushValue], Void);
		push.returnValue(push.add(length, push.constInt(1)));
		var insert = new IrBuilder(), insertArray = insert.argument("array", arrayType), insertPosition = insert.argument("position", I32),
			insertValue = insert.argument("value", element);
		var inserted = insert.call("__value_array_insert_empty", [insertArray, insertPosition], I32);
		insert.call(setName(), [insertArray, inserted, insertValue], Void);
		insert.returnValue(insert.constVoid());
		var unshift = new IrBuilder(), unshiftArray = unshift.argument("array", arrayType), unshiftValue = unshift.argument("value", element),
			unshiftLength = new IrValue(1000000, "$array-length", I32);
		unshift.call(insertName(), [unshiftArray, unshift.constInt(0), unshiftValue], Void);
		unshift.currentBlock().instructions.push(new Located(ArraySize(unshiftLength, unshiftArray), SourceProvenance.generated("value-array-unshift")));
		unshift.returnValue(unshiftLength);
		var pop = new IrBuilder(), popArray = pop.argument("array", arrayType), popLength = new IrValue(1000000, "$array-length", I32);
		pop.currentBlock().instructions.push(new Located(ArraySize(popLength, popArray), SourceProvenance.generated("value-array-pop")));
		var popIndex = pop.sub(popLength, pop.constInt(1)), popValue = pop.call(getName(), [popArray, popIndex], element);
		pop.call("__value_array_remove_at", [popArray, popIndex], Void); pop.returnValue(popValue);
		var shift = new IrBuilder(), shiftArray = shift.argument("array", arrayType), shiftIndex = shift.constInt(0),
			shiftValue = shift.call(getName(), [shiftArray, shiftIndex], element);
		shift.call("__value_array_remove_at", [shiftArray, shiftIndex], Void); shift.returnValue(shiftValue);
		return [new IrFunction(getName(), get.arguments, element, get.blocks), new IrFunction(setName(), set.arguments, Void, set.blocks),
			new IrFunction(pushName(), push.arguments, I32, push.blocks), new IrFunction(insertName(), insert.arguments, Void, insert.blocks),
			new IrFunction(unshiftName(), unshift.arguments, I32, unshift.blocks), new IrFunction(popName(), pop.arguments, element, pop.blocks),
			new IrFunction(shiftName(), shift.arguments, element, shift.blocks)];
	}
}
