// `for (index => element in array)` inside a comprehension binds each element to its index, as it does in a for loop.
function main():Int {
	var names = ["a", "bb", "ccc"];
	var lengths = [for (index => name in names) index * 10 + name.length];
	var evens = [for (index => name in names) if (index % 2 == 0) name.length];
	var positions:Map<String, Int> = [for (index => name in names) name => index];
	var shifted:Map<Int, String> = [for (index => name in names) if (index > 0) index => name + "!"];
	var nested = [for (index => row in [[1, 2], [3]]) for (value in row) index + value];
	var middle = positions.get("bb"),
		last = positions.get("ccc"),
		second = shifted.get(1),
		missing = shifted.get(0);
	var checks = [
		lengths.length == 3
		&& lengths[0] == 1
		&& lengths[1] == 12
		&& lengths[2] == 23,
		evens.length == 2
		&& evens[0] == 1
		&& evens[1] == 3,
		middle != null
		&& middle == 1,
		last != null
		&& last == 2,
		second != null
		&& second == "bb!",
		missing == null,
		nested.length == 3
		&& nested[0] == 1
		&& nested[1] == 2
		&& nested[2] == 4];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
