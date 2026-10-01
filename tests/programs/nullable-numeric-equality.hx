// A nullable number compares for equality with a number of another numeric type: a Float against an Int literal
// widens the literal, and a missing value is never equal to a number.
function main():Int {
	var present:Null<Float> = 40.0;
	var absent:Null<Float> = null;
	var whole:Null<Int> = 2;
	var checks = [
		present == 40,
		!(present == 41),
		present != 41,
		!(present != 40),
		40 == present,
		absent != 40,
		!(absent == 40),
		40 != absent,
		whole == 2,
		whole != 3
	];
	for (check in checks)
		if (!check)
			return 1;
	return 42;
}
