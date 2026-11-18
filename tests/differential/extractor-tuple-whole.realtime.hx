// In a tuple switch an extractor's `_` would be the tuple, which is no value: Haxe rejects a whole-case extractor there.
class Main {
	static function main():Void {
		var x = 1, y = 2;
		var label = switch [x, y] {
			case _.length => 2: "two";
			case _: "other";
		};
		Sys.println(label);
	}
}
