function takesFloat(value:Float):Bool
	return value == 6.0;

function main():Int {
	var assigned:Float = 5;
	var sum = assigned + 0.5;
	var product = 2 * 3.0;
	var quotient = 5 / 2;
	if (sum != 5.5 || product != 6.0 || quotient != 2.5)
		return 1;
	if (!(2 < 2.5) || !(3.0 == 3) || !takesFloat(6))
		return 2;
	return 42;
}
