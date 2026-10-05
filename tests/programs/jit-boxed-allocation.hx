@:noInline function boxed(value:Int):Null<Int> {
	return value;
}

@:noInline function stress(n:Int):Float {
	var a = 1.0, b = 2.0, c = 3.0, d = 4.0, e = 5.0, f = 6.0;
	var keep:Array<Null<Int>> = [];
	var live = {value: 42};
	for (i in 0...n) {
		var before = a + 0.25;
		var x:Null<Int> = i - 10000;
		if (x == null || x != i - 10000)
			return -1;
		a = before + 0.75;
		keep[i & 127] = x;
		b += 2;
		c += 3;
		d += 4;
		e += 5;
		f += 6;
	}
	for (i in 0...128)
		if (keep[i] != n - 128 + ((i - (n & 127) + 128) & 127) - 10000)
			return -2;
	return a + b + c + d + e + f + live.value;
}

function main():Int {
	if (stress(20000) != 420063.0)
		return 1;
	var min = boxed(-2147483647 - 1), max = boxed(2147483647), zero = boxed(0);
	if (min != -2147483647 - 1 || max != 2147483647 || zero != 0)
		return 2;
	var unset:Null<Int> = null;
	if (unset != null)
		return 3;
	var live = boxed(42), caught = false;
	try {
		if (stress(1024) != 21567.0)
			return 4;
		throw "expected";
	} catch (e:Dynamic) {
		caught = true;
	}
	return caught && live == 42 ? 42 : 5;
}
