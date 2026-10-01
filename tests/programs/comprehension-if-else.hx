// A comprehension body can be an if/else chain, not only a filter: `[for (x in xs) if (a) 1 else if (b) 2 else 3]`.
function classify(value:Int):String
	return value < 0 ? "negative" : value == 0 ? "zero" : "positive";

function main():Int {
	var values = [-2, 0, 3, 7];
	var labels = [
		for (value in values)
			if (value < 0) "n" else if (value == 0) "z" else "p"
	];
	var plain = [for (value in values) if (value > 2) value * 10 else value];
	var filtered = [for (value in values) if (value < 0) 1 else if (value > 5) 2];
	var blocks = [
		for (value in values)
			if (value < 0) {
				var twice = value * 2;
				twice;
			} else if (value == 0) {
				100;
			} else {
				value + 1;
			}
	];
	var computed = [
		for (value in values) {
			var shifted = value + 1;
			if (shifted > 3) shifted else 0;
		}
	];
	var nested = [for (outer in 0...3) [for (inner in 0...3) if (inner == outer) 1 else 0]];
	var typed:Array<Int> = [for (value in values) if (value == 0) 0 else if (value == 3) 33 else value];
	var checks = [
		labels.join("") == "nzpp",
		plain.join(",") == "-2,0,30,70",
		filtered.join(",") == "1,2",
		blocks.join(",") == "-4,100,4,8",
		computed.join(",") == "0,0,4,8",
		nested[0].join("") == "100" && nested[1].join("") == "010" && nested[2].join("") == "001",
		typed.join(",") == "-2,0,33,7",
		classify(-1) == "negative"
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
