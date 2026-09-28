// An array comprehension whose block body ends in an if without else keeps
// only the iterations where the condition holds, as in Haxe.
function main():Int {
	var values = [3, -1, 4, -1, 5];
	var names = ["a", "b", "c", "d", "e"];
	var kept = [for (index in 0...values.length) {
		var value = values[index];
		if (value > 0)
			names[index];
	}];
	if (kept.join(",") != "a,c,e")
		return 1;
	var doubled = [for (value in values) if (value > 0) value * 2];
	if (doubled.join(",") != "6,8,10")
		return 2;
	var nested = [for (value in values) {
		var twice = value * 2;
		if (twice > 4) {
			twice + 1;
		}
	}];
	if (nested.join(",") != "7,9,11")
		return 3;
	var any = Lambda.exists(values, value -> value < 0);
	var none = Lambda.exists(values, value -> !Math.isFinite(value * 1.0));
	return any && !none ? 42 : 4;
}
