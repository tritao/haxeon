class Entry {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var objects = [new Entry(17), new Entry(25)];
	var alias = objects;
	alias[1].value = 26;
	if (objects[0].value + objects[1].value != 43)
		return 1;
	var strings = ["a", "bc"], bools = [true, false];
	if (strings[0] + strings[1] != "abc" || !bools[0] || bools[1])
		return 2;
	var nullable:Array<Null<Int>> = [17, null, 25];
	if (nullable[0] != 17 || nullable[1] != null || nullable[2] != 25)
		return 3;
	nullable[1] = 42;
	if (nullable[1] != 42)
		return 4;
	var boxed:Array<Null<Float>> = [1.5, null, Math.NaN];
	var nan = boxed[2];
	if (boxed[0] != 1.5 || boxed[1] != null || nan == null || !Math.isNaN(nan))
		return 5;
	return 42;
}
