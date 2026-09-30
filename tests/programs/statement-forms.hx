function reciprocal(value:Float):Float {
	try
		return 1.0 / checked(value)
	catch (_:Dynamic)
		return -1.0;
}

function checked(value:Float):Float {
	if (value == 0.0)
		throw "zero";
	return value;
}

function rethrows(value:Int):Int {
	try
		throw value
	catch (caught:Int)
		return caught + 1;
}

function main():Int {
	if (reciprocal(4.0) != 0.25 || reciprocal(0.0) != -1.0)
		return 1;
	if (rethrows(5) != 6)
		return 2;
	// A bare block is its own scope and need not end in a value.
	var total = 0;
	{
		var inner = 10;
		for (i in 0...3)
			total += inner + i;
	}
	{
		var inner = 1;
		total += inner;
	}
	if (total != 34)
		return 3;
	// A block whose last statement is an expression still yields its value.
	var value = {
		var a = 20;
		a + 22;
	};
	if (value != 42)
		return 4;
	return 42;
}
