// `++`, `--` and the compound assignments work on a Dynamic local and on a field of a Dynamic value; `target++` as an
// expression is the value before the increment.
function main():Int {
	var object:Dynamic = {count: 1, ratio: 1.5, nested: {depth: 10}};
	var local:Dynamic = 5;
	object.count++;
	object.count++;
	object.count--;
	var before = object.count++;
	var decrementedFrom = object.count--;
	object.ratio++;
	object.ratio += 2;
	object.ratio *= 2;
	object.ratio -= 1.0;
	object.nested.depth += 4;
	object.nested.depth++;
	local++;
	local += 10;
	local--;
	var localBefore = local++;
	var count:Int = object.count;
	var ratio:Float = object.ratio;
	var depth:Int = object.nested.depth;
	var result:Int = local;
	var checks = [
		before == 2,
		decrementedFrom == 3,
		count == 2,
		ratio == 8.0,
		depth == 15,
		localBefore == 15,
		result == 16
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
