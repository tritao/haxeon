enum ParseError {
	Empty;
	BadDigit(at:Int);
}

enum ConfigError {
	Unreadable(cause:ParseError);
	OutOfRange(port:Int);
}

function parsePort(text:String):Result<Int, ParseError> {
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

function port(text:String):Result<Int, ConfigError> {
	var value = try parsePort(text).mapErr(ConfigError.Unreadable);
	if (value > 65535)
		return Err(OutOfRange(value));
	return Ok(value);
}

function check(text:String):Result<Void, ConfigError> {
	try port(text);
	return Ok();
}

function describe(text:String):String
	return switch port(text) {
		case Ok(value): 'port $value';
		case Err(Unreadable(Empty)): "no port given";
		case Err(Unreadable(BadDigit(at))): 'not a digit at $at';
		case Err(OutOfRange(value)): '$value is out of range';
	}

function main():Void {
	for (text in ["8080", "", "80a", "70000"])
		Sys.println(describe(text));
	Sys.println(parsePort("41").map(value -> value + 1).unwrapOr(0));
	Sys.println(check("443").isOk());
	_ = check("oops");
}
