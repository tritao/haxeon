// An assignment to an array or map element is an expression whose value is the assigned value, so it can be a lambda's
// body or the right-hand side of another declaration.
function main():Int {
	var items = [1, 2, 3];
	var store = (index:Int, value:Int) -> items[index] = value;
	var returned = store(1, 20);
	var chained = items[2] = 9;
	var counter = 0;
	var next = () -> {
		counter = counter + 1;
		counter;
	};
	var lookups = [10, 20, 30];
	var position = 0;
	var at = lookups[next() - 1] = 77;
	var table:Map<String, Int> = [];
	var put = (key:String, value:Int) -> table[key] = value;
	var stored = put("a", 5);
	var checks = [
		returned == 20,
		items[1] == 20,
		chained == 9,
		items[2] == 9,
		at == 77,
		lookups[0] == 77 && lookups[1] == 20,
		counter == 1,
		stored == 5,
		table["a"] == 5
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
