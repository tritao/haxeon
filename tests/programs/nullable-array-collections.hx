struct NullableArrayValue {
	public final value:Int;
	public function new(value:Int) { this.value = value; }
}

function main():Int {
	var numbers:Array<Null<Int>> = [1, null, 3];
	var copy = numbers.copy();
	var slice = numbers.slice(1, 3);
	var joined = numbers.concat([4, null]);
	var removed = numbers.splice(1, 2);
	if (copy.length != 3 || copy[0] != 1 || copy[1] != null || copy[2] != 3) return 1;
	if (slice.length != 2 || slice[0] != null || slice[1] != 3) return 2;
	if (joined.length != 5 || joined[3] != 4 || joined[4] != null) return 3;
	if (removed.length != 2 || removed[0] != null || removed[1] != 3 || numbers.length != 1) return 4;
	var values:Array<Null<NullableArrayValue>> = [new NullableArrayValue(9), null];
	var copiedValues = values.copy();
	var first = copiedValues[0];
	if (first == null || first.value != 9 || copiedValues[1] != null) return 5;
	return 42;
}
