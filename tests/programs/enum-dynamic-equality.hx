enum Value implements Equatable {
	Item(value:Int);
}

enum Custom implements Equatable {
	Item(value:Int);

	public function equals(other:Custom):Bool {
		return true;
	}
}

enum Never implements Equatable {
	Item(value:Int);
	public function equals(other:Never):Bool return false;
}

enum GenericValue<T:Equatable> implements Equatable {
	Item(value:T);
	Empty;
}

enum DescriptorOnly {
	Wrapped(value:GenericValue<Int>);
}

class EnumHolder<T> {
	public var item:T;
	public function new(item:T) this.item = item;
}

function makeGeneric<T:Equatable>(value:T):GenericValue<T> return GenericValue.Item(value);

@:hlNative("haxeon_runtime", "__reflect_is_enum")
extern function enumKindProbe(value:Dynamic):Bool;

function main():Int {
	var first:Dynamic = Value.Item(1), same:Dynamic = Value.Item(1), different:Dynamic = Value.Item(2);
	if (!(first == same) || first == different) return 1;
	if (!Type.enumEq(first, same) || Type.enumEq(first, different)) return 2;
	var customFirst:Dynamic = Custom.Item(1), customDifferent:Dynamic = Custom.Item(2);
	if (!(customFirst == customDifferent)) return 3;
	if (Type.enumEq(customFirst, customDifferent)) return 4;
	if (!Std.isOfType(first, Value)) return 5;
	var typed:Value = cast first;
	if (!Type.enumEq(typed, Value.Item(1))) return 6;
	var values:Array<Dynamic> = [first];
	if (!values.contains(same) || values.indexOf(different) != -1) return 7;
	var never:Dynamic = Never.Item(1);
	if (never == never || [never].contains(never)) return 8;
	if (!values.remove(same) || values.length != 0) return 9;
	var unequal:Array<Dynamic> = [never];
	if (unequal.remove(never) || unequal.length != 1) return 10;
	var typedValues:Array<Value> = [Value.Item(1), Value.Item(1)];
	var alias:Array<Dynamic> = cast typedValues;
	var aliasLeft:Dynamic = alias[0], aliasRight:Dynamic = alias[1];
	if (!(aliasLeft == aliasRight)) return 11;
	var numbers:Array<GenericValue<Int>> = [makeGeneric(1), makeGeneric(1), GenericValue.Empty];
	var texts:Array<GenericValue<String>> = [makeGeneric("1"), GenericValue.Empty];
	var dynamicNumbers:Array<Dynamic> = cast numbers, dynamicTexts:Array<Dynamic> = cast texts;
	if (!(dynamicNumbers[0] == dynamicNumbers[1])) return 12;
	if (dynamicNumbers[2] == dynamicTexts[1]) return 13;
	if (!Type.enumEq(dynamicNumbers[0], dynamicNumbers[1]) || Type.enumEq(dynamicNumbers[2], dynamicTexts[1])) return 14;
	var erased:Dynamic = numbers;
	var erasedView:Array<Dynamic> = cast erased;
	if (!(erasedView[0] == erasedView[1])) return 15;
	if (!Std.isOfType(dynamicNumbers[0], GenericValue)) return 16;
	var restored:GenericValue<Int> = cast dynamicNumbers[0];
	switch restored { case Item(value) if (value == 1): default: return 17; }
	var wrongTypeRejected = false;
	try { var wrong:GenericValue<String> = cast dynamicNumbers[0]; } catch (_:Dynamic) wrongTypeRejected = true;
	if (!wrongTypeRejected) return 18;
	var reflectedA:Dynamic = Reflect.field(new EnumHolder(makeGeneric(7)), "item");
	var reflectedB:Dynamic = Reflect.field(new EnumHolder(makeGeneric(7)), "item");
	if (!(reflectedA == reflectedB) || !Type.enumEq(reflectedA, reflectedB)) return 19;
	if (Reflect.compare(first, first) != 0xAABBCCDD || Reflect.compare(first, same) != 0xAABBCCDD
		|| Reflect.compare(null, first) != 0xAABBCCDD || Reflect.compare(first, null) != 0xAABBCCDD) return 20;
	var number:Dynamic = 7, decimal:Dynamic = 7.5, flag:Dynamic = false, text:Dynamic = "enum";
	var list:Array<Int> = [], erasedList:Dynamic = list, object:Dynamic = new EnumHolder(7);
	var callback:Dynamic = () -> 7;
	if (!enumKindProbe(first) || !enumKindProbe(customFirst) || !enumKindProbe(never) || !enumKindProbe(dynamicNumbers[0])
		|| !enumKindProbe(dynamicTexts[0]) || !enumKindProbe(dynamicNumbers[2]) || enumKindProbe(null) || enumKindProbe(number) || enumKindProbe(decimal)
		|| enumKindProbe(flag) || enumKindProbe(text) || enumKindProbe(erasedList) || enumKindProbe(object) || enumKindProbe(callback)) return 23;
	#if wasm
	if (Reflect.compare(number, number) != 0 || Reflect.compare(null, number) != -1) return 24;
	#end
	if (CompareCensus.perform(8) != 336) return 21;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated(), result = CompareCensus.perform(count);
		var bytes = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (result != count * 42 || bytes != 0) return 22;
	}
	#end
	return 42;
}

/** Enum kind checks must not allocate or depend on nominal descriptor dispatch. */
class CompareCensus {
	static final value:Dynamic = Value.Item(7);
	@:expose public static function perform(count:Int):Int {
		var sum = 0;
		for (index in 0...count)
			if (Reflect.compare(value, value) == 0xAABBCCDD && Reflect.compare(null, value) == 0xAABBCCDD
				&& Reflect.compare(value, null) == 0xAABBCCDD && enumKindProbe(value))
				sum += 42;
		return sum;
	}
}
