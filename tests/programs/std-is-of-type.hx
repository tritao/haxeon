interface HasValue {
	function getValue():Int;
}

class BaseValue {}

class Value extends BaseValue implements HasValue {
	public function new() {}

	public function getValue():Int
		return 42;
}

enum State {
	Ready;
}

function stringLength(value:Dynamic):Int {
	if (Std.isOfType(value, String))
		return value.length;
	return 0;
}

function functionValue():Int
	return 42;

function main():Int {
	var text:Dynamic = "value",
		number:Dynamic = 42,
		fraction:Dynamic = 42.9,
		flag:Dynamic = true,
		wide:haxe.Int64 = 42,
		dynamicWide:Dynamic = wide,
		values:Dynamic = [1, 2],
		objectValue = new Value(),
		object:Dynamic = objectValue,
		callable:Dynamic = functionValue,
		boundMethod:Dynamic = objectValue.getValue,
		state:Dynamic = State.Ready;
	return Std.isOfType(text, String)
		&& !Std.isOfType(text, Int)
		&& Std.isOfType(number, Int)
		&& Std.isOfType(values, Array)
		&& Std.isOfType(object, Value)
		&& Std.isOfType(object, BaseValue)
		&& Std.isOfType(object, HasValue)
		&& Std.isOfType(state, State)
		&& !Std.isOfType(null, Value)
		&& stringLength(text) == 5
		&& stringLength(number) == 0
		&& Std.int(fraction) == 42
		&& Std.int(flag) == 1
		&& Std.int(dynamicWide) == 42
		&& Reflect.isObject(values)
		&& Reflect.isObject(object)
		&& !Reflect.isObject(text)
		&& !Reflect.isObject(callable)
		&& !Reflect.isObject(boundMethod) ? 42 : 1;
}
