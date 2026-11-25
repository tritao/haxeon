package app;

import lib.Shapes;

/** Recursive anonymous structures are shared definitions of every section that uses them. */
typedef Node = {next:Null<Node>, value:Int};

enum Step {
	Stop;
	Move(dx:Int, dy:Int);
	Turn(angle:Float);
}

/** Calls, closures, statics, globals, enums and anonymous structures across two module sections and the shared one. */
class Main {
	static var visits = 0;
	static final greeting = "sections";

	static function main() {
		var shapes:Array<Shape> = [new Square(2), new Circle(1.5), Shapes.unit()];
		var total = 0.0;
		for (shape in shapes)
			total += shape.area();
		var names = [for (shape in shapes) shape.name()];
		var list:Node = {next: null, value: 1};
		for (value in 2...5)
			list = {next: list, value: value};
		var sum = 0, node:Null<Node> = list;
		while (node != null) {
			sum += node.value;
			node = node.next;
		}
		var counts = new Map<String, Int>();
		for (name in names)
			counts.set(name, (counts.exists(name) ? counts.get(name) : 0) + 1);
		var steps = [Move(1, 2), Turn(0.5), Stop, Move(-3, 4)];
		var x = 0, y = 0;
		for (step in steps)
			switch step {
				case Move(dx, dy):
					x += dx;
					y += dy;
				case Turn(_):
					visits++;
				case Stop:
			}
		var scale = (factor:Float) -> total * factor;
		try {
			Shapes.check(-1);
		} catch (error:String) {
			trace('caught $error');
		}
		trace('$greeting ${Math.round(scale(10))} $names $sum ${counts.get("square")} $x,$y $visits ${Std.string(steps[0])}');
		trace(Std.string({next: null, value: 7}));
		trace(Shapes.describe({name: "first", value: list.value}));
	}
}
