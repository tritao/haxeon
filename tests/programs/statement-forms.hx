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

function assigns(value:Float):Float {
	var result = 0.0;
	try
		result = checked(value) * 2.0
	catch (_:Dynamic)
		result = -2.0;
	return result;
}

function main():Int {
	if (reciprocal(4.0) != 0.25 || reciprocal(0.0) != -1.0)
		return 1;
	if (rethrows(5) != 6)
		return 2;
	if (assigns(3.0) != 6.0 || assigns(0.0) != -2.0)
		return 5;
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
	// Blocks nest, an empty one is a statement, and object literals keep their meaning.
	var depth = 0;
	{
		{
			{
				depth = 3;
			}
		};
	}
	{}
	var record = {name: 7};
	if (depth != 3 || record.name != 7)
		return 6;
	return 42;
}
