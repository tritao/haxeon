// Register allocation through traps (release builds): a catch can run from any instruction of its try, so what it reads keeps its
// register for the whole try. Each function holds a value from before the try, makes short-lived temporaries of the same type
// inside it (candidates for that value's register), and throws partway, after one of them; the catch then reads the value.
@:noInline function fail(when:Int, at:Int):Int {
	if (when == at)
		throw "stop";
	return at * 3;
}

@:noInline function beforeTry(seed:Int, when:Int):Int {
	var kept = seed * 7;
	try {
		var a = fail(when, 1) + seed;
		var b = fail(when, 2) + a;
		var c = fail(when, 3) + b;
		return c;
	} catch (e:String) {
		return kept;
	}
}

@:noInline function updatedInTry(seed:Int, when:Int):Int {
	var progress = seed;
	try {
		var a = fail(when, 1);
		progress = a + 1;
		var b = fail(when, 2) * 2;
		progress = b + 2;
		var c = fail(when, 3) * 5;
		return c;
	} catch (e:String) {
		return progress;
	}
}

@:noInline function nested(seed:Int, inner:Int, outer:Int):Int {
	var outerKept = seed + 100;
	try {
		var innerKept = seed + 10;
		try {
			var t = fail(inner, 1) + fail(outer, 2);
			return t;
		} catch (e:String) {
			var u = fail(outer, 3) + innerKept;
			return u;
		}
	} catch (e:String) {
		return outerKept;
	}
}

@:noInline function rethrown(seed:Int):String {
	var label = "kept-" + seed;
	try {
		try {
			var temp = "temp-" + fail(1, 1);
			return temp;
		} catch (e:String) {
			var other = "other-" + seed;
			throw other;
		}
	} catch (e:String) {
		return label + "/" + e;
	}
}

function main():Int {
	var checks = [
		beforeTry(2, 1) == 14, beforeTry(2, 2) == 14, beforeTry(2, 3) == 14, beforeTry(2, 0) == 2 + 3 + 6 + 9,
		updatedInTry(5, 1) == 5, updatedInTry(5, 2) == 4, updatedInTry(5, 3) == 14, updatedInTry(5, 0) == 45,
		nested(1, 1, 0) == 9 + 11, nested(1, 1, 3) == 101, nested(1, 0, 2) == 20, nested(1, 0, 0) == 3 + 6,
		rethrown(4) == "kept-4/other-4"
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return 100 + index;
	return 42;
}
