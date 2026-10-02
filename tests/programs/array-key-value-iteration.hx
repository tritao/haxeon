// `for (index => element in array)` visits every element with its index; the loop variables are fresh each iteration.
function sum(values:Array<Int>):Int {
	var total = 0;
	for (index => value in values)
		total += index * value;
	return total;
}

function main():Int {
	var names = ["a", "b", "c"];
	var joined = "";
	for (position => name in names)
		joined += position + name + ";";
	var closures:Array<() -> Int> = [];
	for (index => value in [10, 20, 30])
		closures.push(() -> index * 100 + value);
	var firstOnly = -1;
	for (index => value in [5, 6, 7]) {
		if (value == 6) {
			firstOnly = index;
			break;
		}
	}
	var nested = 0;
	for (row => cells in [[1, 2], [3, 4]])
		for (column => cell in cells)
			nested += (row + 1) * (column + 1) * cell;
	var empty:Array<Int> = [];
	var emptyCount = 0;
	for (index => value in empty)
		emptyCount++;
	var checks = [
		sum([10, 20, 30]) == 80,
		joined == "0a;1b;2c;",
		closures[0]() == 10,
		closures[2]() == 230,
		firstOnly == 1,
		nested == 1 * 1 * 1 + 1 * 2 * 2 + 2 * 1 * 3 + 2 * 2 * 4,
		emptyCount == 0
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
