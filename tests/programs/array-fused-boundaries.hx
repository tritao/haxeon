function readInt(values:Array<Int>, index:Int):Int {
	// Eval returns null for an invalid read; HL and Wasm use the existing throwing bounds contract.
	#if eval
	if (index < 0 || index >= values.length)
		throw "Array index out of bounds";
	#end
	return values[index];
}

function readFloat(values:Array<Float>, index:Int):Float {
	#if eval
	if (index < 0 || index >= values.length)
		throw "Array index out of bounds";
	#end
	return values[index];
}

function main():Int {
	var ints = [17, 25], floats = [1.25, 2.75];
	if (readInt(ints, 0) + readInt(ints, ints.length - 1) != 42)
		return 1;
	if (readFloat(floats, 0) + readFloat(floats, floats.length - 1) != 4.0)
		return 2;
	var caught = 0;
	var live = 6.25;
	for (index in [ints.length, -1]) {
		try {
			readInt(ints, index);
		} catch (_:Dynamic) {
			caught++;
		}
		if (live != 6.25 || ints[0] != 17)
			return 3;
	}
	for (index in [floats.length, -1]) {
		try {
			readFloat(floats, index);
		} catch (_:Dynamic) {
			caught++;
		}
		if (live != 6.25 || floats[0] != 1.25)
			return 4;
	}
	if (caught != 4)
		return 5;
	// Keep a Float live across a bounds failure in this very function, not just in its caller.
	var atEnd = ints.length;
	try {
		#if eval
		if (atEnd >= ints.length)
			throw "Array index out of bounds";
		#end
		live += ints[atEnd];
	} catch (_:Dynamic) {
		live += 1.0;
	}
	if (live != 7.25)
		return 6;
	return 42;
}
