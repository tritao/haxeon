class BoundsNode {
	public var value:Int;

	public function new(v:Int) {
		value = v;
	}
}

function sum(a:Array<Int>):Int {
	var result = 0;
	for (i in 0...a.length)
		result += a[i];
	return result;
}

function grow(a:Array<Int>):Void {
	a.push(8);
}

function shrink(a:Array<Int>):Void {
	a.pop();
}

function main():Int {
	var a = [1, 2, 3, 4];
	if (sum(a) != 10 || sum([]) != 0)
		return 1;
	var f = [0.5, 1.5, 2.0], fs = 0.0;
	for (i in 0...f.length)
		fs += f[i];
	if (fs != 4.0)
		return 2;
	var nodes = [new BoundsNode(2), new BoundsNode(4)], ns = 0;
	for (i in 0...nodes.length)
		ns += nodes[i].value;
	if (ns != 6)
		return 3;
	var alias = a, total = 0;
	for (i in 0...a.length) {
		alias[i] = a[i] + 1;
		total += a[i];
	}
	if (total != 14)
		return 4;
	// The upper bound is captured before the loop; growing and shrinking calls must
	// retain checks. A shrinking loop stops before reading a removed element.
	var growing = [1, 2], gs = 0;
	for (i in 0...growing.length) {
		grow(growing);
		gs += growing[i];
	}
	if (gs != 3 || growing.length != 4)
		return 5;
	var shrinking = [1, 2, 3, 4], ss = 0;
	for (i in 0...shrinking.length) {
		shrink(shrinking);
		if (i >= shrinking.length)
			break;
		ss += shrinking[i];
	}
	if (ss != 3 || shrinking.length != 1)
		return 6;
	var caught = 0;
	try {
		for (i in 0...a.length) {
			caught += a[i];
			if (i == 1)
				throw "done";
		}
	} catch (e:Dynamic) {
		if (caught != 5)
			return 7;
	}
	var nested = 0;
	for (i in 0...a.length)
		for (j in (i + 1)...a.length)
			nested += a[i] + a[j];
	if (nested != 42)
		return 8;
	return 42;
}
