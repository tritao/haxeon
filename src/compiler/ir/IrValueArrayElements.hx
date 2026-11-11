package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrTypeCodec;

/** Typed element boundaries, lowered to scalar call components when the backend supports them. */
class IrValueArrayElements {
	public static inline final PREFIX = "$value-array:element:";
	final element:IrType;
	/** Physical value carried at element boundaries; the array itself retains its logical element type. */
	public final storage:IrType;
	final helpers:IrValueArraySlotHelpers;
	final bridge:IrValueArrayBridge;
	final suffix:String;
	var iteratorUsed:Bool = false;

	public function new(element:IrType, helpers:IrValueArraySlotHelpers, bridge:IrValueArrayBridge) {
		this.element = element;
		this.helpers = helpers;
		this.bridge = bridge;
		storage = bridge.storage;
		suffix = haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
	}

	public function getName():String return PREFIX + "get:" + suffix;
	public function setName():String return PREFIX + "set:" + suffix;
	public function pushName():String return PREFIX + "push:" + suffix;
	public function insertName():String return PREFIX + "insert:" + suffix;
	public function unshiftName():String return PREFIX + "unshift:" + suffix;
	public function popName():String return PREFIX + "pop:" + suffix;
	public function shiftName():String return PREFIX + "shift:" + suffix;
	public function iteratorNewName():String return PREFIX + "iterator-new:" + suffix;
	public function iteratorArrayName():String return PREFIX + "iterator-array:" + suffix;
	public function iteratorAdvanceName():String return PREFIX + "iterator-advance:" + suffix;
	public function iteratorNextName():String return PREFIX + "iterator-next:" + suffix;
	public function useIterator():Void iteratorUsed = true;
	public function natives():Array<IrNative> return !iteratorUsed ? [] : [
		{name:iteratorNewName(), library:"haxeon_runtime", symbol:"__value_iterator_new", arguments:[Array(element)], result:Iterator(element)},
		{name:iteratorArrayName(), library:"haxeon_runtime", symbol:"__value_iterator_array", arguments:[Iterator(element)], result:Array(element)},
		{name:iteratorAdvanceName(), library:"haxeon_runtime", symbol:"__value_iterator_advance", arguments:[Iterator(element)], result:I32}
	];
	public static function spliceNativeName(element:IrType):String
		return "$value-array:native-splice:" + haxe.crypto.Base64.encode(IrTypeCodec.encode(element));

	public function functions():Array<IrFunction> {
		var arrayType:IrType = Array(element), get = new IrBuilder(), array = get.argument("array", arrayType),
			index = get.argument("index", I32);
		get.call(helpers.checker([], false), [array, index], Void);
		get.returnValue(bridge.readValue(get, array, index, storage, []));
		var set = new IrBuilder(), target = set.argument("array", arrayType), position = set.argument("index", I32),
			value = set.argument("value", storage);
		set.call("__value_array_ensure", [target, position], Void);
		bridge.writeValue(set, target, position, value, storage, []);
		set.call("__value_array_mark", [target, position], Void);
		set.returnValue(set.constVoid());
		var push = new IrBuilder(), pushArray = push.argument("array", arrayType), pushValue = push.argument("value", storage),
			length = new IrValue(1000000, "$array-length", I32);
		push.currentBlock().instructions.push(new Located(ArraySize(length, pushArray), SourceProvenance.generated("value-array-push")));
		push.call(setName(), [pushArray, length, pushValue], Void);
		push.returnValue(push.add(length, push.constInt(1)));
		var insert = new IrBuilder(), insertArray = insert.argument("array", arrayType), insertPosition = insert.argument("position", I32),
			insertValue = insert.argument("value", storage);
		var inserted = insert.call("__value_array_insert_empty", [insertArray, insertPosition], I32);
		insert.call(setName(), [insertArray, inserted, insertValue], Void);
		insert.returnValue(insert.constVoid());
		var unshift = new IrBuilder(), unshiftArray = unshift.argument("array", arrayType), unshiftValue = unshift.argument("value", storage),
			unshiftLength = new IrValue(1000000, "$array-length", I32);
		unshift.call(insertName(), [unshiftArray, unshift.constInt(0), unshiftValue], Void);
		unshift.currentBlock().instructions.push(new Located(ArraySize(unshiftLength, unshiftArray), SourceProvenance.generated("value-array-unshift")));
		unshift.returnValue(unshiftLength);
		var pop = new IrBuilder(), popArray = pop.argument("array", arrayType), popLength = new IrValue(1000000, "$array-length", I32);
		pop.currentBlock().instructions.push(new Located(ArraySize(popLength, popArray), SourceProvenance.generated("value-array-pop")));
		switch storage {
			case EnumTag(_):
				var absent = pop.createBlock(), present = pop.createBlock();
				pop.branch(pop.equal(popLength, pop.constInt(0)), absent, present);
				pop.select(absent); pop.returnValue(pop.constNull(storage)); pop.select(present);
			default:
		}
		var popIndex = pop.sub(popLength, pop.constInt(1)), popValue = pop.call(getName(), [popArray, popIndex], storage);
		pop.call("__value_array_remove_at", [popArray, popIndex], Void); pop.returnValue(popValue);
		var shift = new IrBuilder(), shiftArray = shift.argument("array", arrayType), shiftIndex = shift.constInt(0),
			shiftValue:IrValue;
		switch storage {
			case EnumTag(_):
				var length = new IrValue(1000000, "$array-length", I32), absent = shift.createBlock(), present = shift.createBlock();
				shift.currentBlock().instructions.push(new Located(ArraySize(length, shiftArray), SourceProvenance.generated("value-array-shift")));
				shift.branch(shift.equal(length, shift.constInt(0)), absent, present);
				shift.select(absent); shift.returnValue(shift.constNull(storage)); shift.select(present);
			default:
		}
		shiftValue = shift.call(getName(), [shiftArray, shiftIndex], storage);
		shift.call("__value_array_remove_at", [shiftArray, shiftIndex], Void); shift.returnValue(shiftValue);
		var result = [new IrFunction(getName(), get.arguments, storage, get.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, getName()))), new IrFunction(setName(), set.arguments, Void, set.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, setName()))),
			new IrFunction(pushName(), push.arguments, I32, push.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, pushName()))), new IrFunction(insertName(), insert.arguments, Void, insert.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, insertName()))),
			new IrFunction(unshiftName(), unshift.arguments, I32, unshift.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, unshiftName()))), new IrFunction(popName(), pop.arguments, storage, pop.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, popName()))),
			new IrFunction(shiftName(), shift.arguments, storage, shift.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, shiftName())))];
		if (iteratorUsed) {
			var next = new IrBuilder(), iterator = next.argument("iterator", Iterator(element)),
				iteratorArray = next.call(iteratorArrayName(), [iterator], arrayType),
				iteratorIndex = next.call(iteratorAdvanceName(), [iterator], I32);
			next.call(helpers.checker([], false), [iteratorArray, iteratorIndex], Void);
			next.returnValue(bridge.readValue(next, iteratorArray, iteratorIndex, storage, []));
			result.push(new IrFunction(iteratorNextName(), next.arguments, storage, next.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayElement, iteratorNextName()))));
		}
		return result;
	}
}
