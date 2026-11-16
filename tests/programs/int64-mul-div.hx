import haxe.Int64;

// Int64.mul, div and mod behave as Haxe's: multiplication wraps, division truncates toward zero, the remainder takes the
// dividend's sign, and the minimum divided by -1 wraps to the minimum.
function main():Int {
	var big = Int64.make(1, 0); // 2^32
	if (Int64.toStr(Int64.mul(big, big)) != "0" || Int64.toStr(Int64.mul(Int64.ofInt(-3), Int64.ofInt(7))) != "-21")
		return 1;
	if (Int64.toStr(Int64.mul(big, Int64.ofInt(5))) != "21474836480")
		return 2;
	if (Int64.toStr(Int64.div(Int64.ofInt(-7), Int64.ofInt(2))) != "-3"
		|| Int64.toStr(Int64.mod(Int64.ofInt(-7), Int64.ofInt(2))) != "-1")
		return 3;
	var minimum = Int64.make(0x80000000, 0);
	if (Int64.compare(Int64.div(minimum, Int64.ofInt(-1)), minimum) != 0
		|| Int64.toStr(Int64.mod(minimum, Int64.ofInt(-1))) != "0")
		return 4;
	return 42;
}
