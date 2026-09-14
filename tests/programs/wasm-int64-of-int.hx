function main():Int {
	var minimumInt = -2147483647 - 1;
	return haxe.Int64.compare(haxe.Int64.ofInt(0), haxe.Int64.make(0, 0)) == 0
		&& haxe.Int64.compare(haxe.Int64.ofInt(1), haxe.Int64.make(0, 1)) == 0
		&& haxe.Int64.compare(haxe.Int64.ofInt(-1), haxe.Int64.make(-1, -1)) == 0
		&& haxe.Int64.compare(haxe.Int64.ofInt(2147483647), haxe.Int64.make(0, 2147483647)) == 0
		&& haxe.Int64.compare(haxe.Int64.ofInt(minimumInt), haxe.Int64.make(-1, minimumInt)) == 0
		? 42 : 0;
}
