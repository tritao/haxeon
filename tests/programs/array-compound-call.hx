class Churn {
	/** Grows the array enough to move its storage, so an address taken before the call would be stale after it. */
	public static function growInts(values:Array<Int>):Int {
		for (i in 0...1000)
			values.push(i);
		return 5;
	}

	public static function growFloats(values:Array<Float>):Float {
		for (i in 0...1000)
			values.push(i);
		return 2.5;
	}

	public static function shrink(values:Array<Int>):Int {
		while (values.length > 1)
			values.pop();
		return 1;
	}
}

function main():Int {
	// A compound assignment around a call that reallocates the array writes into the array, not a stale buffer.
	var ints = [1, 2, 3];
	ints[1] += Churn.growInts(ints);
	if (ints[1] != 7 || ints.length != 1003)
		return 1;
	var floats = [0.5, 1.5];
	floats[0] += Churn.growFloats(floats);
	if (floats[0] != 3.0 || floats.length != 1002)
		return 2;

	// A read after a call that removed the element still raises.
	var shrunk = [1, 2, 3];
	var position = 2;
	var before = shrunk[position];
	Churn.shrink(shrunk);
	var raised = false;
	try {
		before += shrunk[position];
	} catch (error:Dynamic) {
		raised = true;
	}
	if (before != 3 || !raised)
		return 3;

	// A callee that shrinks the array during the update cannot make the write corrupt memory.
	var small = [1, 2, 3];
	small[2] += Churn.shrink(small);
	if (small[0] != 1)
		return 4;
	return 42;
}
