// `%` binds tighter than `*` and `/` in Haxe, and all three associate to the left.
function main():Int {
	var a = 10, b = 7, c = 4, d = 3;
	if (a * b % c != 30)
		return 1;
	if (a % b * c != 12)
		return 2;
	if (a * b % c * d != 90)
		return 3;
	if (100 / a % c != 50)
		return 4;
	if (a % b % c != 3)
		return 5;
	if (a - b * 9 % c + d != 6)
		return 6;
	var x = 7.5, y = 5.5, z = 2.0;
	if (x * y % z != 11.25)
		return 7;
	if (x % y * z != 4.0)
		return 8;
	if ((a * b) % c != 2 || (a * b % c) != 30)
		return 9;
	var seed = 100;
	seed = seed * 31 % 1000 + 7;
	if (seed != 3107)
		return 10;
	return 42;
}
