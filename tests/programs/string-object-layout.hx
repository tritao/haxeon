// Strings cross every runtime boundary as HashLink String objects carrying their length.
class Box {
	public var name:String;

	public function new(name:String) {
		this.name = name;
	}
}

function main():Int {
	var text = "alpha,beta";
	if (text.length != 10 || text.charCodeAt(9) != "a".code)
		return 1;
	var joined = text.split(",").join("+");
	if (joined != "alpha+beta" || joined.length != 10)
		return 2;
	var dynamicText:Dynamic = "alp" + "ha";
	if (dynamicText != "alpha" || !Std.isOfType(dynamicText, String))
		return 3;
	var typed:String = dynamicText;
	if (typed.length != 5)
		return 4;
	var names:Array<Dynamic> = ["x", "y"];
	var typedNames:Array<String> = cast names;
	if (typedNames.indexOf("y") != 1)
		return 5;
	var counts = new Map<String, Int>();
	counts.set("one", 1);
	counts.set("two", 2);
	var keys = [for (key in counts.keys()) key];
	keys.sort(Reflect.compare);
	if (keys.join(",") != "one,two" || keys[1].length != 3)
		return 6;
	var labels = new Map<Int, String>();
	labels.set(7, "seven");
	if (labels.get(7) != "seven" || labels.get(7).length != 5)
		return 7;
	var record:Dynamic = {};
	Reflect.setField(record, "field", "value");
	if (Reflect.field(record, "field") != "value" || Reflect.fields(record)[0].length != 5)
		return 8;
	if (Std.string(new Box("boxed")).indexOf("Box") < 0 || Std.string(["a", "b"]) != "[a, b]")
		return 9;
	try {
		throw "thrown";
	} catch (message:String) {
		if (message.length != 6)
			return 10;
	}
	if (Std.parseInt("42") != 42 || StringTools.trim("  padded ") != "padded")
		return 11;
	return 42;
}
