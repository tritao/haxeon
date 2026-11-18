// `value.match(pattern)` on an enum value: nested patterns, constants, `_` and alternatives (`A | B`), with the value
// evaluated once.
enum Shape {
	Circle(radius:Int);
	Rect(width:Int, height:Int);
	Group(lead:Shape, rest:Array<Shape>);
	Empty;
}

class Main {
	static var reads = 0;

	static function shape(value:Shape):Shape {
		reads++;
		return value;
	}

	static function main():Void {
		var group = Group(Circle(1), [Empty]);
		Sys.println(group.match(Group(Circle(_), _)));
		Sys.println(group.match(Group(Rect(_, _), _)));
		Sys.println(group.match(Group(Circle(1), [Empty])));
		Sys.println(group.match(Group(Rect(_, _) | Circle(_), _)));
		Sys.println(Rect(2, 3).match(Circle(_) | Rect(2, _)));
		Sys.println(Empty.match(Circle(_) | Rect(_, _)));
		Sys.println(Empty.match(_));
		Sys.println([for (item in [Circle(1), Empty, Rect(1, 1)]) item.match(Empty | Circle(_))]);
		Sys.println(shape(Circle(4)).match(Circle(3) | Circle(4)) + " " + reads);
	}
}
