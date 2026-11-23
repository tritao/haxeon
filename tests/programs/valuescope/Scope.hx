package valuescope;

import valuescope.other.Mode.*;
import valuescope.other.Mode.Signal.*;

enum Color {
	Red;
	Green;
}

enum abstract Local(Int) to Int {
	var Alpha = 5;
}

class Scope {
	static function tagged(tag:Tag):Int
		return tag;

	// The subject's abstract names its values in a pattern, alone or several in one case.
	static function kind(tag:Tag):String
		return switch tag {
			case Type, Array: "type";
			case Plain: "plain";
			case _: "other";
		};

	public static function run(failures:Array<String>):Void {
		// The package's Tag is loaded, but its `Type` is not in scope here: `Type` is Haxe's.
		var tag:Tag = Plain;
		if (Type.getEnumName(Color) != "valuescope.Color")
			failures.push("Type.getEnumName");
		if (Type.enumIndex(Green) != 1)
			failures.push("Type.enumIndex");
		// Where a Tag is expected, its values are.
		if (tagged(Type) != 13 || tag != 1 || kind(Array) != "type" || kind(Plain) != "plain")
			failures.push("expected Tag");
		var values:Array<Int> = [1, 2];
		if (values.length != 2)
			failures.push("Array");
		// A value of this module's own abstract, and an imported abstract's and enum's through `import Type.*`.
		var alpha = Alpha, fast = Fast;
		if (alpha != 5 || fast != 7 || Type.enumIndex(Stop(1)) != 1 || Type.enumIndex(Go) != 0)
			failures.push("own and imported values");
	}
}
