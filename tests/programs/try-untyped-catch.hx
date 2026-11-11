function fail(value:Int):Int {
	if (value > 0)
		throw "failed";
	return value;
}

function main():Int {
	var total = 0;
	try {
		fail(1);
	} catch (_) {
		total += 20;
	}
	var value = try fail(2) catch (error) 20;
	return total + value + 2;
}
