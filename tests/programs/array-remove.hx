class Item {
	public final value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var numbers = [20, 1, 21];
	if (!numbers.remove(1) || numbers.length != 2 || numbers[0] + numbers[1] != 41)
		return 1;
	if (numbers.remove(99))
		return 2;
	var strings = ["alpha", "beta"];
	if (!strings.remove("alpha") || strings[0] != "beta")
		return 3;
	var booleans = [true, false];
	if (!booleans.remove(false) || booleans.length != 1)
		return 4;
	var floats = [1.5, 2.5];
	if (!floats.remove(1.5) || floats[0] != 2.5)
		return 5;
	var first = new Item(1), second = new Item(2), objects = [first, second];
	if (!objects.remove(first) || objects.length != 1 || objects[0].value != 2)
		return 6;
	return numbers[0] + objects[0].value + numbers[1] - 1;
}
