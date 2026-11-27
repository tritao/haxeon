// `try value` with no `catch` gives a Result's Ok value, or returns its Err from the enclosing function: in declared and
// inferred functions, in lambdas, inside other expressions, and after `mapErr` converts the error type. Returning through it
// runs `defer`. `try` followed by `catch` still catches exceptions.
enum ParseError {
	Empty;
	BadDigit(at:Int);
}

enum ConfigError {
	Unreadable(cause:ParseError);
	TooLarge(value:Int);
}

// A module's own `Ok` and `Err` do not change what `try` returns.
enum Verdict {
	Ok;
	Err;
}

function digits(text:String):Result<Int, ParseError> {
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

function sum(left:String, right:String):Result<Int, ParseError>
	return Ok(try digits(left) + try digits(right));

function port(text:String):Result<Int, ConfigError> {
	var value = try digits(text).mapErr(ConfigError.Unreadable);
	if (value > 65535)
		return Err(TooLarge(value));
	return Ok(value);
}

function inferred(text:String) {
	var value = try digits(text);
	return Ok(value * 2);
}

var saved = 0;

function save(text:String):Result<Int, ParseError> {
	try digits(text);
	saved++;
	return Ok(saved);
}

var cleaned = 0;

function guarded(text:String):Result<Int, ParseError> {
	defer cleaned++;
	var value = try digits(text);
	return Ok(value);
}

function describe(result:Result<Int, ParseError>):String
	return switch result {
		case Ok(value): "ok " + value;
		case Err(Empty): "empty";
		case Err(BadDigit(at)): "bad digit at " + at;
	}

function verdict(result:Result<Int, ParseError>):Verdict
	return result.isOk() ? Ok : Err;

function main():Int {
	if (describe(sum("40", "2")) != "ok 42" || describe(sum("4", "x")) != "bad digit at 0"
		|| describe(sum("", "1")) != "empty")
		return 1;
	switch port("8080") {
		case Ok(8080):
		default:
			return 2;
	}
	switch port("80a") {
		case Err(Unreadable(BadDigit(2))):
		default:
			return 3;
	}
	switch port("70000") {
		case Err(TooLarge(70000)):
		default:
			return 4;
	}
	if (describe(inferred("21")) != "ok 42" || describe(inferred("?")) != "bad digit at 0")
		return 5;
	_ = save("1");
	_ = save("x");
	if (saved != 1 || describe(save("2")) != "ok 2")
		return 6;
	var doubled = ["1", "2", "x"].map(text -> {
		var value = try digits(text);
		return Ok(value * 2);
	});
	if (describe(doubled[1]) != "ok 4" || describe(doubled[2]) != "bad digit at 0")
		return 7;
	var chained = digits("5").andThen(value -> Ok(value + try digits("37")));
	if (describe(chained) != "ok 42")
		return 8;
	switch [verdict(chained), verdict(digits(""))] {
		case [Ok, Err]:
		default:
			return 8;
	}
	var caught = try Std.parseInt("12") catch (e:Dynamic) 0;
	if (caught != 12)
		return 9;
	_ = guarded("x");
	_ = guarded("1");
	if (cleaned != 2)
		return 10;
	return 42;
}
