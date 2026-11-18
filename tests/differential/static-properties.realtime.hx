// Static properties with accessors, of a class and of an abstract, as in Haxe: a read calls `get_x` and a write `set_x`, wherever
// source names the property (qualified, bare in its own type, `+=`, `++` as a statement and as a value); inside its own accessor
// an `@:isVar` property is its variable.
class Settings {
	static var stored = 3;

	public static var scale(get, set):Int;

	static function get_scale():Int
		return stored * 2;

	static function set_scale(value:Int):Int
		return stored = value;

	public static var limit(get, never):Int;

	static function get_limit():Int
		return 100;

	@:isVar public static var level(get, set):Int = 1;

	static function get_level():Int
		return level + 1000;

	static function set_level(value:Int):Int
		return level = value * 10;

	public static var label(get, null):String;

	static function get_label():String {
		if (label == null)
			label = "settings";
		return label + "!";
	}

	public static function adjust():Void {
		scale = 7;
		Sys.println(scale);
		scale += 1;
		Sys.println(scale);
		scale++;
		Sys.println(scale);
		var before = scale--;
		Sys.println(before + " " + scale);
	}
}

abstract Counter(Int) {
	static var store = 5;

	public static var current(get, set):Int;

	static function get_current():Int
		return store;

	static function set_current(value:Int):Int {
		store = value;
		return value;
	}

	public static var doubled(get, never):Int;

	static function get_doubled():Int
		return current * 2;

	public static function bump():Int {
		current++;
		current += 10;
		return current;
	}
}

class Main {
	static function main() {
		Sys.println(Settings.scale);
		Settings.scale = 10;
		Sys.println(Settings.scale);
		Settings.scale += 1;
		Sys.println(Settings.scale);
		Settings.scale++;
		Sys.println(Settings.scale);
		var old = Settings.scale++;
		Sys.println(old + " " + Settings.scale);
		Sys.println(Settings.limit);
		Sys.println(Settings.level);
		Settings.level = 4;
		Sys.println(Settings.level);
		Sys.println(Settings.label);
		Settings.adjust();
		Sys.println(Counter.current);
		Counter.current = 9;
		Sys.println(Counter.doubled);
		Sys.println(Counter.bump());
		Counter.current++;
		Sys.println(Counter.current);
	}
}
