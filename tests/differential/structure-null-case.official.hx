// `case null` beside structure patterns matches a null subject before any field is read. A switch over a structure or class
// instance whose cases are only `_`, names or `null` matches the whole value.
enum Shape {
	Circle(radius:Int);
	Square;
}

class Point {
	public var x:Int;
	public var y:Int;

	public function new(x:Int, y:Int) {
		this.x = x;
		this.y = y;
	}
}

typedef Item = {count:Int, shape:Shape};

class Main {
	static var reads = 0;

	static function item(value:Null<Item>):Null<Item> {
		reads++;
		return value;
	}

	static function describe(value:Null<Item>):String {
		return switch value {
			case {
				count:0
			}
			: "empty";
			case null: "missing";
			case {
				shape:Circle(radius)
			}
			: "circle " + radius;
			case {
				shape:Square, count:count
			}
			: "square " + count;
		};
	}

	static function guarded(value:Null<Item>, allow:Bool):String {
		return switch item(value) {
			case null if (allow): "allowed null";
			case {
				count:1
			}
			: "one";
			case other: other == null ? "other null" : "other " + other.count;
		};
	}

	static function main():Void {
		for (value in [null, {count: 0, shape: Square}, {count: 2, shape: Circle(5)}, {count: 3, shape: Square}])
			Sys.println(describe(value));
		Sys.println(guarded(null, true) + ", " + guarded(null, false) + ", " + guarded({count: 1, shape: Square},
			false) + ", "
			+ guarded({count: 4, shape: Square}, true) + ", reads " + reads);
		var points:Array<Null<Point>> = [new Point(1, 2), null, new Point(0, 0)];
		for (point in points)
			switch point {
				case null:
					Sys.println("no point");
				case {
					x:0, y:0
				}
				: Sys.println("origin");
				case whole = {x: x}:
					Sys.println("x " + x + " y " + whole.y);
			}
		var point = new Point(3, 4);
		Sys.println(switch point {
			case named: named.x + named.y;
		});
		var increment = (value:Int) -> value + 1;
		Sys.println(switch increment {
			case _: "function";
		});
		var maybe:Null<Point> = null;
		Sys.println(switch maybe {
			case null: "null point";
			case _: "a point";
		});
	}
}
