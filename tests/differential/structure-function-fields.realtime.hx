// A structure's `function` fields are read-only fields of function type, as in Haxe: a literal's lambdas stand for them,
// an optional argument may be omitted, and an @:optional one may be absent.
typedef Shape = {
	function area(width:Int, height:Int):Int;
	function describe(?label:String):Void;
	@:optional function scale():Int;
	var sides:Int;
}

class Main {
	static function main() {
		var square:Shape = {
			area: (width, height) -> width * height,
			describe: (?label: String) -> Sys.println(label == null ? "unlabelled" : label),
			sides: 4
		};
		Sys.println(square.area(3, 4) + square.sides);
		square.describe();
		square.describe("square");
		Sys.println(square.scale == null);
	}
}
