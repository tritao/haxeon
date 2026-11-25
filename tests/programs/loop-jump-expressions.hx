// `break` and `continue` are expressions, as in Haxe: a comprehension's value or a loop body's value can skip an element or
// end the loop, as `if (skip) continue else value`, a switch arm or a conditional.
function main():Int {
	var values = [1, 2, 3, 4, 5];
	var skipped = [for (value in values) if (value == 2) continue else value];
	var stopped = [for (value in values) if (value > 2) break else value];
	var switched = [for (value in values) switch value {
		case 2: continue;
		case 4: break;
		case _: value * 10;
	}];
	var statement = [for (value in values) {
		if (value == 3)
			continue;
		value;
	}];
	var filtered = [for (value in values) if (value > 4) break else if (value % 2 == 1) value];
	var ranged = [for (index in 0...5) if (index == 1) continue else index];
	var squares = [for (value in values) value => if (value == 3) continue else value * value];
	var nested = [for (outer in 0...3)[for (inner in 0...3) if (inner == outer) continue else inner]];

	var total = 0;
	for (value in values) {
		var counted = value == 4 ? continue : value;
		total += counted;
	}
	var steps = 0;
	while (true) {
		var next = if (steps >= 3) break else steps + 1;
		steps = next;
	}
	var found = -1;
	var index = 0;
	do {
		found = values[index] == 3 ? break : found;
		index++;
	} while (index < values.length);

	var checks = [
		skipped.join(",") == "1,3,4,5",
		stopped.join(",") == "1,2",
		switched.join(",") == "10,30",
		statement.join(",") == "1,2,4,5",
		filtered.join(",") == "1,3",
		ranged.join(",") == "0,2,3,4",
		[for (key in squares.keys()) key].length == 4 && squares.get(5) == 25 && !squares.exists(3),
		nested.map(row -> row.join("")).join("|") == "12|02|01",
		total == 11,
		steps == 3,
		index == 2
	];
	for (check in 0...checks.length)
		if (!checks[check])
			return check + 1;
	return 42;
}
