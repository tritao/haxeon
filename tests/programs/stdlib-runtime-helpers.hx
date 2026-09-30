// String.lastIndexOf, Int64.fromFloat, Std.random and Reflect.compare, which Wasm implements
// without the HashLink runtime; the parity suite checks both Wasm targets against HL.
function lastIndexOf():Int {
	var text = "abcabc";
	return text.lastIndexOf("bc") == 4 && text.lastIndexOf("bc", 3) == 1 && text.lastIndexOf("bc", 4) == 4 && text.lastIndexOf("bc", 100) == 4
		&& text.lastIndexOf("abc", 0) == 0 && text.lastIndexOf("x") == -1 && text.lastIndexOf("") == 6 && text.lastIndexOf("", 2) == 2
		&& text.lastIndexOf("", 100) == 6 && text.lastIndexOf("bc", -1) == -1 && "ab".lastIndexOf("abc") == -1 ? 0 : 1;
}

function fromFloat():Int {
	return haxe.Int64.compare(haxe.Int64.fromFloat(42.9), haxe.Int64.ofInt(42)) == 0
		&& haxe.Int64.compare(haxe.Int64.fromFloat(-42.9), haxe.Int64.ofInt(-42)) == 0
		&& haxe.Int64.toFloat(haxe.Int64.fromFloat(9007199254740991.0)) == 9007199254740991.0
		&& haxe.Int64.compare(haxe.Int64.fromFloat(4294967296.0), haxe.Int64.make(1, 0)) == 0 ? 0 : 2;
}

function random():Int {
	if (Std.random(0) != 0 || Std.random(-5) != 0 || Std.random(1) != 0)
		return 4;
	var seen = [false, false, false, false];
	for (index in 0...200) {
		var value = Std.random(4);
		if (value < 0 || value >= 4)
			return 4;
		seen[value] = true;
	}
	return seen.indexOf(false) < 0 ? 0 : 4;
}

function compare():Int {
	var none:Dynamic = null,
		three:Dynamic = 3,
		four:Dynamic = 4,
		half:Dynamic = 4.5,
		alsoThree:Dynamic = 3.0;
	var apple:Dynamic = "apple",
		apricot:Dynamic = "apricot",
		ap:Dynamic = "ap",
		yes:Dynamic = true,
		no:Dynamic = false;
	return Reflect.compare(none, none) == 0
		&& Reflect.compare(none, three) == -1
		&& Reflect.compare(three, none) == 1
		&& Reflect.compare(three, four) == -1
		&& Reflect.compare(four, three) == 1
		&& Reflect.compare(three, three) == 0
		&& Reflect.compare(three, half) == -1
		&& Reflect.compare(half, four) == 1
		&& Reflect.compare(three, alsoThree) == 0
		&& Reflect.compare(apple, apricot) == -1
		&& Reflect.compare(apricot, apple) == 1
		&& Reflect.compare(ap, apple) == -1
		&& Reflect.compare(apple, "apple") == 0
		&& Reflect.compare(yes, no) == 1
		&& Reflect.compare(no, no) == 0 ? 0 : 8;
}

function main():Int {
	var failures = lastIndexOf() | fromFloat() | random() | compare();
	return failures == 0 ? 42 : failures;
}
