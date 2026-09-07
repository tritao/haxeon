function main():Int {
	Sys.sleep(1.0);
	var value = 10;
	if (true) {
		var value = 20;
		var inside = value + 1;
		Sys.println("inside");
	}
	var after = value + 1;
	Sys.println("after");
	for (index in 0...1) {
		var loopOnly = index + 30;
		Sys.println("loop");
	}
	Sys.println("post-loop");
	try {
		throw "boom";
	} catch (error:String) {
		var catchOnly = error;
		Sys.println("catch");
	}
	Sys.println("post-catch");
	return after;
}
