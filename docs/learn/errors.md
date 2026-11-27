# Errors as values

A failure that the caller is meant to handle, such as input that does not parse, is returned as a `Result<T, E>`:
`Ok(value)` when it worked, `Err(error)` when it did not. `E` is usually an enum whose cases name each failure and carry
its data, so a `switch` over the result is checked for every case. A failure that is a bug, such as an index out of
range, still throws.

`try value`, with no `catch`, gives the `Ok` value of a `Result`, and returns its `Err` from the enclosing function. The
function must return a `Result` with the same error type, so `port` converts `ParseError` with `mapErr`, where the case
`ConfigError.Unreadable` serves as the function that wraps it. A `try` that a `catch` follows is still an exception
handler.

A `Result<Void, E>` is an operation that succeeds with no value: `Ok()` makes one, and `case Ok():` matches it. A
`Result` must be used. Leaving one unhandled in a statement is error E1033, so `main` writes `_ = check("oops");` to
drop the result on purpose.

```haxe
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
```

```text title="Output"
port 8080
no port given
not a digit at 2
70000 is out of range
42
true
```

[Example project](examples/errors/)

[Language support](../reference/LANGUAGE_SUPPORT.md)
