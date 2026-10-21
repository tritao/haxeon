class DynamicStringPeer {
	public function new() {}

	public function bar(value:Int):Int
		return value + 1;

	public function indexOf(value:String):Int
		return value.length + 99;
}

function main():Int {
	var peer:Dynamic = new DynamicStringPeer();
	if (peer.bar(1) != 2 || peer.indexOf("ab") != 101)
		return 1;
	var text:Dynamic = "ababc";
	if (text.length != 5 || text.charAt(1) != "b" || text.indexOf("ab") != 0 || text.indexOf("ab", 1) != 2)
		return 2;
	var method:Dynamic = Reflect.field(text, "indexOf");
	if (method == null || !Reflect.isFunction(method))
		return 3;
	if (method("ab") != 0 || method("ab", 1) != 2)
		return 18;
	var index:String->Int = method;
	var indexFrom:(String, Int) -> Int = method;
	text = "other";
	if (index("ab") != 0 || indexFrom("ab", 1) != 2)
		return 13;
	text = "ababc";
	if (text.indexOf("ab", null) != 0 || text.substring(2, null) != "abc" || text.substr(2, null) != "abc")
		return 14;
	if (text.lastIndexOf("ab") != 2 || text.lastIndexOf("ab", 1) != 0)
		return 4;
	if (text.substring(1) != "babc" || text.substring(1, 3) != "ba" || text.substr(-2) != "bc")
		return 5;
	if (text.toUpperCase() != "ABABC" || text.toLowerCase() != "ababc" || text.toString() != "ababc")
		return 6;
	if (text.charCodeAt(0) != 97 || text.charCodeAt(20) != null || text.charAt(20) != "")
		return 7;
	var parts:Array<String> = text.split("b");
	if (parts.length != 3 || parts[2] != "c")
		return 8;
	var record:Dynamic = haxe.Json.parse('{"rule":"fabrication.insert.drawing.test"}');
	if (record.rule.indexOf("fabrication.insert.drawing.") != 0)
		return 9;
	if (Reflect.field(text, "missing") != null)
		return 10;
	var caught = false;
	var evaluated = 0;
	var argument = () -> {
		evaluated++;
		return 1;
	};
	try {
		text.missing(argument());
	} catch (error:Dynamic) {
		caught = Std.string(error).indexOf("Null") >= 0;
	}
	if (!caught || evaluated != 1)
		return 11;
	var callback:() -> Int = null;
	caught = false;
	try {
		callback();
	} catch (error:Dynamic) {
		caught = Std.string(error).indexOf("Null") >= 0;
	}
	if (!caught)
		return 12;
	var empty:Dynamic = "";
	if (empty.charAt(0) != "" || empty.charCodeAt(0) != null || empty.indexOf("") != 0)
		return 15;
	var unicode:Dynamic = "😀x";
	if (unicode.length != 3 || unicode.charCodeAt(0) != 0xD83D || unicode.charAt(2) != "x" || unicode.indexOf("x") != 2)
		return 16;
	var absent:Dynamic = null;
	caught = false;
	try {
		absent.charAt(0);
	} catch (error:Dynamic) {
		caught = Std.string(error).indexOf("Null") >= 0;
	}
	if (!caught)
		return 17;
	var nonFunction:Dynamic = 1;
	caught = false;
	try {
		nonFunction();
	} catch (error:Dynamic) {
		caught = Std.string(error).indexOf("non-function") >= 0;
	}
	if (!caught)
		return 19;
	var invalid:Dynamic = {method: 1};
	caught = false;
	try {
		invalid.method();
	} catch (error:Dynamic) {
		caught = Std.string(error).indexOf("non-function") >= 0;
	}
	if (!caught)
		return 20;
	return 42;
}
