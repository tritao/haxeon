// Structure patterns, as Haxe matches them: field by field, nested, with captures of the whole value or of a field, on a
// structure or a class instance, in a switch used as a value or as a statement.
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

class Main {
	static function describe(point:{x:Int, y:Int}):String
		return switch point {
			case {
				x:0, y:0
			}
			: "origin";
			case {
				x:0, y:y
			}
			: "on y at " + y;
			case {
				y:0
			}
			: "on x";
			case whole = {x: x} if (x > 10): "far " + whole.y;
			case _: "somewhere";
		};

	static function main():Void {
		Sys.println(describe({x: 0, y: 0}));
		Sys.println(describe({x: 0, y: 4}));
		Sys.println(describe({x: 3, y: 0}));
		Sys.println(describe({x: 30, y: 2}));
		Sys.println(describe({x: 3, y: 2}));
		var item = {name: "a", shape: Circle(2), at: {x: 1, y: 2}};
		switch item {
			case {
				shape:Circle(radius), at:{x:1}
			}
			: Sys.println("circle " + radius);
			case {
				shape:Square
			}
			: Sys.println("square");
			case {
				shape:Circle(_)
			}
			: Sys.println("other circle");
		}
		var total:Int = switch item {
			case {
				name:name, at:inner = {y: y}
			}
			: name.length + y + inner.x;
		};
		Sys.println(total);
		switch new Point(5, 6) {
			case {
				x:5, y:y
			}
			: Sys.println("point " + y);
			case _:
				Sys.println("no point");
		}
		// A statement may leave values of an Int field unmatched.
		var plain = {x: 1, y: 2};
		switch plain {
			case {
				x:1, y:y
			}
			: Sys.println("y " + y);
		}
		switch plain {
			case {
				x:9
			}
			: Sys.println("nine");
		}
		var label = switch {
			flag:true, text:"t"
		}
		{
			case {
				flag:true, text:text
			}
			: "on " + text;
			case {
				flag:false
			}
			: "off";
		};
		Sys.println(label);
	}
}
