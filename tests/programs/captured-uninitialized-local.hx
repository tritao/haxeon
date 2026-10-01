function use(callback:() -> Int):Int {
	return callback();
}

function risky(fail:Bool):Int {
	if (fail)
		throw "failed";
	return 5;
}

// A local declared without a value may be captured once it has been assigned.
function viaTry(fail:Bool):Int {
	var value:Int;
	try {
		value = risky(fail);
	} catch (error:Dynamic) {
		value = 7;
	}
	return use(() -> value + 1);
}

function branches(flag:Bool):Int {
	var chosen:Int;
	if (flag)
		chosen = 1;
	else
		chosen = 2;
	return use(() -> chosen * 10);
}

function mutated():Int {
	var count:Int;
	count = 0;
	var increment = () -> {
		count = count + 1;
		return count;
	};
	increment();
	var after = increment();
	return count + after;
}

function text(flag:Bool):String {
	var label:String;
	if (flag)
		label = "on";
	else
		label = "off";
	var describe = () -> label + "!";
	return describe();
}

function main():Int {
	var total = viaTry(false) + viaTry(true) + branches(true) + branches(false) + mutated();
	return total - 6 + (text(true) == "on!" && text(false) == "off!" ? 0 : 100);
}
