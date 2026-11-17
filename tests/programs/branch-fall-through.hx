// A branch whose taken side is written next jumps to the other side on the complement of its test. For floats the complement of
// `<` is "not less", taken when either side is NaN; for integers it is `>=`, signed, so a negative side compares below zero.
@:noInline function below(a:Int, b:Int):Int {
	if (a < b)
		return 1;
	return 2;
}

@:noInline function atMost(a:Int, b:Int):Int {
	if (a <= b)
		return 1;
	return 2;
}

@:noInline function belowFloat(a:Float, b:Float):Int {
	if (a < b)
		return 1;
	return 2;
}

@:noInline function atMostFloat(a:Float, b:Float):Int {
	if (a <= b)
		return 1;
	return 2;
}

@:noInline function same(a:Int, b:Int):Int {
	if (a == b)
		return 1;
	return 2;
}

@:noInline function missing(value:Null<String>):Int {
	if (value == null)
		return 1;
	return 2;
}

@:noInline function countDown(from:Int):Int {
	var steps = 0, index = from;
	while (index >= 0) {
		steps++;
		index--;
	}
	return steps;
}

function main():Int {
	var nan = Math.NaN;
	var checks = [
		below(-1, 0) == 1 && below(0, -1) == 2 && below(-5, -5) == 2 && below(0x7FFFFFFF, -1) == 2,
		atMost(-1, 0) == 1 && atMost(-5, -5) == 1 && atMost(0, -1) == 2 && atMost(-2147483648, 0) == 1,
		belowFloat(1.0, 2.0) == 1 && belowFloat(2.0, 1.0) == 2 && belowFloat(nan, 1.0) == 2
			&& belowFloat(1.0, nan) == 2,
		atMostFloat(1.0, 1.0) == 1 && atMostFloat(2.0, 1.0) == 2 && atMostFloat(nan, 1.0) == 2
			&& atMostFloat(nan, nan) == 2,
		belowFloat(-0.5, 0.0) == 1 && atMostFloat(-0.0, 0.0) == 1,
		same(-3, -3) == 1 && same(-3, 3) == 2,
		missing(null) == 1 && missing("a") == 2,
		countDown(3) == 4 && countDown(-1) == 0 && countDown(0) == 1
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return 100 + index;
	return 42;
}
