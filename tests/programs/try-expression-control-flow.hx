// In a try expression, a return, break or continue in a catch leaves the enclosing function or loop, as in Haxe, and the
// expression's value is the try's or the catch's.
function parse(text:String):Int {
	var value = Std.parseInt(text);
	if (value == null)
		throw 'not a number: $text';
	return value;
}

function firstNumber(texts:Array<String>):Int {
	var found = -1;
	for (text in texts) {
		var value = try parse(text) catch (_:Dynamic) {
			continue;
		};
		found = value;
		break;
	}
	return found;
}

function orExit(text:String):Int {
	var value = try parse(text) catch (_:Dynamic) {
		return -7;
	};
	return value * 2;
}

function sumUntilBad(texts:Array<String>):Int {
	var total = 0;
	for (text in texts)
		total += try parse(text) catch (_:Dynamic) {
			break;
		};
	return total;
}

function main():Int {
	if (firstNumber(["a", "b", "12", "13"]) != 12)
		return 1;
	if (orExit("21") != 42 || orExit("x") != -7)
		return 2;
	if (sumUntilBad(["1", "2", "x", "4"]) != 3)
		return 3;
	var nullable:Null<Int> = try parse("x") catch (_:Dynamic) null;
	return nullable == null ? 42 : 4;
}
