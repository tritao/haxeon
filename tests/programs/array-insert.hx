class Value {
	public final number:Int;

	public function new(number:Int) {
		this.number = number;
	}
}

function main():Int {
	var integers = [40, 2];
	integers.insert(1, 1);
	var floats = [1.0];
	floats.insert(0, 0.5);
	var booleans = [false];
	booleans.insert(-1, true);
	var strings = ["two"];
	strings.insert(0, "one");
	var objects = [new Value(2)];
	objects.insert(0, new Value(40));
	return integers[0] + integers[1] + (floats[0] < 1.0 ? 1 : 0) + (booleans[0] ? 1 : 0)
		+ (strings[0] == "one" ? 1 : 0) + objects[1].number - 4;
}
