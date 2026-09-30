function classify(n:Int):String {
	var label = "none";
	for (i in 0...n) {
		if (i % 3 == 0)
			label = "fizz";
		else if (i % 3 == 1)
			label = "buzz";
		else
			label = "none";
	}
	return label;
}

function joinAll(count:Int):String {
	var text = "";
	for (i in 0...count)
		text += "ab" + (i % 2 == 0 ? "-" : "+");
	return text;
}

function same(a:String, b:String):Int {
	var score = 0;
	if (a == "k")
		score += 1;
	if (b == "k")
		score += 2;
	if (a == b)
		score += 4;
	if (a == "k" && b == "k")
		score += 8;
	return score;
}

function thrown(n:Int):String {
	try {
		for (i in 0...n)
			if (i == 3)
				throw "three";
	} catch (e:String) {
		return e + "!" + "three";
	}
	return "none";
}

function main():Int {
	var failures = 0;
	if (classify(1) != "fizz" || classify(2) != "buzz" || classify(3) != "none" || classify(0) != "none")
		failures += 1;
	if (joinAll(4) != "ab-ab+ab-ab+")
		failures += 2;
	if (same("k", "k") != 15 || same("k", "x") != 1 || same("x", "k") != 2 || same("q", "q") != 4)
		failures += 4;
	if (thrown(2) != "none" || thrown(5) != "three!three")
		failures += 8;
	return failures == 0 ? 42 : failures;
}
