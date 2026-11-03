class InlinedNullProbe {
	public static var entered:Int = 0;
	public static var arguments:Int = 0;
	public static function argument():Int { arguments++; return 3; }
}

class InlinedNullBox {
	public function new() {}
	public function straight(value:Int):Int { InlinedNullProbe.entered++; return value; }
	public inline function branch(value:Int):Int {
		InlinedNullProbe.entered++;
		if (value > 0) return value;
		return 0;
	}
}

function missingInlinedBox():InlinedNullBox {
	var value:Dynamic = null;
	return cast value;
}

function main():Int {
	try {
		missingInlinedBox().straight(InlinedNullProbe.argument());
		return 1;
	} catch (error:Dynamic) {}
	if (InlinedNullProbe.entered != 0 || InlinedNullProbe.arguments != 1) return 2;
	try {
		missingInlinedBox().branch(InlinedNullProbe.argument());
		return 3;
	} catch (error:Dynamic) {}
	if (InlinedNullProbe.entered != 0 || InlinedNullProbe.arguments != 2) return 4;
	return new InlinedNullBox().straight(42) == 42 ? 42 : 5;
}
