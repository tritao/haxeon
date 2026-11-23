function ints(value:Null<Int>, other:Null<Int>):Bool {
	var values:Array<Null<Int>> = [1000, null, 2000, 1000, null];
	return values.contains(value) && values.contains(null)
		&& values.indexOf(value) == 0 && values.indexOf(null) == 1
		&& values.lastIndexOf(value) == 3 && values.lastIndexOf(null) == 4
		&& values.lastIndexOf(value, -3) == 0 && values.lastIndexOf(null, 3) == 1
		&& values.remove(value) && values.indexOf(value) == 2
		&& values.remove(null) && values.indexOf(null) == 2
		&& values.remove(other) && !values.remove(other)
		&& values.remove(value) && !values.contains(value)
		&& values.remove(null) && values.length == 0 && !values.contains(null);
}

function floats(value:Null<Float>, other:Null<Float>):Bool {
	var values:Array<Null<Float>> = [1.25, null, 2.5, 1.25, null];
	return values.contains(value) && values.contains(null)
		&& values.indexOf(value) == 0 && values.indexOf(null) == 1
		&& values.lastIndexOf(value) == 3 && values.lastIndexOf(null) == 4
		&& values.lastIndexOf(value, -3) == 0 && values.lastIndexOf(null, 3) == 1
		&& values.remove(value) && values.indexOf(value) == 2
		&& values.remove(null) && values.indexOf(null) == 2
		&& values.remove(other) && !values.remove(other)
		&& values.remove(value) && !values.contains(value)
		&& values.remove(null) && values.length == 0 && !values.contains(null);
}

function bools(value:Null<Bool>, other:Null<Bool>):Bool {
	var values:Array<Null<Bool>> = [false, null, true, false, null];
	return values.contains(value) && values.contains(null)
		&& values.indexOf(value) == 0 && values.indexOf(null) == 1
		&& values.lastIndexOf(value) == 3 && values.lastIndexOf(null) == 4
		&& values.lastIndexOf(value, -3) == 0 && values.lastIndexOf(null, 3) == 1
		&& values.remove(value) && values.indexOf(value) == 2
		&& values.remove(null) && values.indexOf(null) == 2
		&& values.remove(other) && !values.remove(other)
		&& values.remove(value) && !values.contains(value)
		&& values.remove(null) && values.length == 0 && !values.contains(null);
}

function dynamics(value:Dynamic, other:Dynamic):Bool {
	var values:Array<Dynamic> = [1000, null, 2000, 1000, null];
	return values.contains(value) && values.contains(null)
		&& values.indexOf(value) == 0 && values.indexOf(null) == 1
		&& values.lastIndexOf(value) == 3 && values.lastIndexOf(null) == 4
		&& values.lastIndexOf(value, -3) == 0 && values.lastIndexOf(null, 3) == 1
		&& values.remove(value) && values.indexOf(value) == 2
		&& values.remove(null) && values.indexOf(null) == 2
		&& values.remove(other) && !values.remove(other)
		&& values.remove(value) && !values.contains(value)
		&& values.remove(null) && values.length == 0 && !values.contains(null);
}

function main():Int {
	if (!ints(1000, 2000))
		return 1;
	if (!floats(1.25, 2.5))
		return 2;
	if (!bools(false, true))
		return 3;
	if (!dynamics(1000, 2000))
		return 4;
	return 42;
}
