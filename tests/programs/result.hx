// The root package's Result<T, E>: an error enum names each failure, the caller matches it, and the methods transform the
// value or the error without unwrapping by hand.
enum ParseError {
	Empty;
	BadDigit(at:Int);
}

enum ConfigError {
	Unreadable(cause:ParseError);
	OutOfRange(value:Int);
}

function parse(text:String):Result<Int, ParseError> {
	if (text.length == 0)
		return Err(Empty);
	var value = 0;
	for (index in 0...text.length) {
		var code = text.charCodeAt(index);
		if (code < "0".code || code > "9".code)
			return Err(BadDigit(index));
		value = value * 10 + code - "0".code;
	}
	return Ok(value);
}

function port(text:String):Result<Int, ConfigError>
	return parse(text).mapErr(ConfigError.Unreadable).andThen(value -> value < 65536
		? Ok(value) : Err(OutOfRange(value)));

function describe(result:Result<Int, ConfigError>):String
	return switch result {
		case Ok(value): "port " + value;
		case Err(Unreadable(Empty)): "empty";
		case Err(Unreadable(BadDigit(at))): "bad digit at " + at;
		case Err(OutOfRange(value)): value + " is out of range";
	}

function main():Int {
	if (!parse("42").isOk() || parse("4x").isOk() || !parse("").isErr())
		return 1;
	if (parse("42").map(value -> value + 1).unwrapOr(0) != 43 || parse("x").map(value -> value + 1).unwrapOr(-1) != -1)
		return 2;
	if (parse("7").map(value -> "#" + value).unwrapOr("") != "#7")
		return 3;
	if (describe(port("8080")) != "port 8080" || describe(port("")) != "empty")
		return 4;
	if (describe(port("80a")) != "bad digit at 2" || describe(port("70000")) != "70000 is out of range")
		return 5;
	if (parse("12").unwrap() != 12)
		return 6;
	var thrown = false;
	try {
		parse("").unwrap();
	} catch (error:haxe.Exception) {
		thrown = error.message == "unwrap() of Err(Empty)";
	}
	if (!thrown)
		return 7;
	var results = [parse("1"), parse("?"), parse("3")];
	var total = 0;
	for (result in results)
		total += result.unwrapOr(100);
	if (total != 104)
		return 8;
	return 42;
}
