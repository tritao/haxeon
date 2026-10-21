class Base {
	public function new() {}
}

class Child extends Base {
	public function new() {
		super();
	}
}

function main():Int {
	// Native split uses the host String descriptor, even inside a loaded module.
	var boxed:Dynamic = "ababc".split("b");
	var parts:Array<String> = boxed;
	if (parts.length != 3 || parts[0] != "a" || parts[2] != "c")
		return 1;
	var alias:Array<String> = boxed;
	parts[0] = "changed";
	if (alias[0] != "changed")
		return 2;
	// Inferred literals use the loaded module's String descriptor.
	var local = ["tail"];
	var joined = parts.concat(local);
	if (joined.length != 4 || joined[3] != "tail")
		return 3;
	var reverse = local.concat(parts);
	if (reverse.length != 4 || reverse[0] != "tail" || reverse[1] != "changed")
		return 4;
	var erasedLeft:Array<Dynamic> = cast parts;
	var erasedRight:Array<Dynamic> = cast local;
	var erasedJoined:Dynamic = erasedLeft.concat(erasedRight);
	var recovered:Array<String> = erasedJoined;
	if (recovered.length != 4 || recovered[3] != "tail")
		return 5;
	var receiver:Dynamic = "ababc";
	var dynamicParts:Array<String> = receiver.split("b");
	if (dynamicParts[1] != "a")
		return 6;
	var empty:Array<String> = (cast "".split("b") : Dynamic);
	if (empty.length != 1 || empty[0] != "")
		return 7;
	var rejected = false;
	var numbers:Dynamic = [1, 2];
	try {
		var invalid:Array<String> = numbers;
	} catch (error:Dynamic) {
		rejected = Std.string(error).indexOf("Array element type mismatch") >= 0;
	}
	if (!rejected)
		return 8;
	// Shared reference layout does not permit mutable nominal array covariance.
	rejected = false;
	var children:Dynamic = [new Child()];
	try {
		var invalid:Array<Base> = children;
	} catch (error:Dynamic) {
		rejected = Std.string(error).indexOf("Array element type mismatch") >= 0;
	}
	if (!rejected)
		return 9;
	return 42;
}
