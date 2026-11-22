// A structure's property fields, as in Haxe: (default, default) is a plain field, (default, null) and (default, never) are read
// through the structure but not written.
typedef Point = {
	var x(default, null):Int;
	var y(default, never):Int;
	var label(default, default):String;
}

class Main {
	static function main() {
		var point:Point = {x: 1, y: 2, label: "a"};
		point.label = "b";
		Sys.println(point.x + point.y + point.label);
	}
}
