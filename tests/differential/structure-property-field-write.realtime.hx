// A structure's (default, null) field cannot be written through the structure: Haxe reports "This expression cannot be
// accessed for writing".
typedef Point = {
	var x(default, null):Int;
}

class Main {
	static function main() {
		var point:Point = {x: 1};
		point.x = 2;
		Sys.println(point.x);
	}
}
