// Several functions convert Dynamic records to the same structure, and to a record holding an array of it: each conversion checks
// and copies the fields, through one helper per target type whichever function asks for it.
typedef Point = {x:Int, y:Int, ?label:String};
typedef Path = {points:Array<Point>};

class Reader {
	public static function point(value:Dynamic):Point
		return value;

	public static function sum(value:Dynamic):Int {
		var p:Point = value;
		return p.x + p.y;
	}

	public static function path(value:Dynamic):Path
		return value;
}

function main():Int {
	var record:Dynamic = {x: 3, y: 4, label: "a"};
	var first = Reader.point(record);
	var all = Reader.path({points: [{x: 1, y: 2}, {x: 5, y: 6}]}).points;
	var missing = try {
		Reader.sum({x: 1});
		false;
	} catch (error:Dynamic) true;
	return first.x == 3 && first.label == "a" && Reader.sum(record) == 7 && all.length == 2 && all[1].y == 6
		&& all[0].label == null
		&& missing ? 42 : 1;
}
