function choose(flag:Bool):Int {
	var value = 0;
	if (flag) value = 20; else value = 21;
	if (value < 0) return 0;
	return value;
}

function main():Int {
	var sum = 0;
	for (i in 0...2) {
		if (i == 0) sum += choose(true); else sum += choose(false);
	}
	try {
		if (sum == 41) throw "caught";
		return 1;
	} catch (error:Dynamic) {
		return sum + 1;
	}
}
