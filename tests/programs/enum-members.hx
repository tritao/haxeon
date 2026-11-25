// An enum declares methods and static members like a class: instance methods take the value as `this` (named or
// implicit), static methods and variables belong to the enum, and both reach each other unqualified inside it.
interface Measured {
	function size():Int;
}

enum Kind implements Measured {
	Scalar;
	Pair;
	Quad;

	public static final ALL:Array<Kind> = [Scalar, Pair, Quad];
	public static var lookups:Int = 0;
	static final FIRST = first();

	public static function parse(label:String):Null<Kind> {
		lookups++;
		for (kind in ALL)
			if (kind.label() == label)
				return kind;
		return null;
	}

	static function first():Kind
		return Scalar;

	public static function initial():Kind
		return FIRST;

	public function components():Int
		return switch this {
			case Scalar: 1;
			case Pair: 2;
			case Quad: 4;
		}

	public function label():String
		return switch this {
			case Scalar: "scalar";
			case Pair: "pair";
			case Quad: "quad";
		}

	public function isVector():Bool
		return components() > 1;

	public function size():Int
		return this.components() * 4;
}

enum Shape {
	Circle(radius:Float);
	Square(side:Float);
	Group(shapes:Array<Shape>);

	public static function unit():Shape
		return Square(1.0);

	public function area():Float
		return switch this {
			case Circle(radius): 3.0 * radius * radius;
			case Square(side): side * side;
			case Group(shapes):
				var total = 0.0;
				for (shape in shapes)
					total += shape.area();
				total;
		}
}

enum Slot<T> {
	Empty;
	Full(value:T);

	public function or(fallback:T):T
		return switch this {
			case Empty: fallback;
			case Full(value): value;
		}
}

function measure(value:Measured):Int
	return value.size();

function main():Int {
	if (Pair.components() != 2 || !Quad.isVector() || Scalar.isVector())
		return 1;
	var kind:Kind = Quad;
	if (kind.label() != "quad" || kind.size() != 16 || measure(kind) != 16)
		return 2;
	if (Kind.parse("pair") != Pair || Kind.parse("none") != null || Kind.lookups != 2)
		return 3;
	Kind.lookups = 0;
	if (Kind.lookups != 0 || Kind.ALL.length != 3 || Kind.initial() != Scalar)
		return 4;
	if (Group([Circle(1.0), Shape.unit(), Square(2.0)]).area() != 8.0)
		return 5;
	var empty:Slot<Int> = Empty, full:Slot<String> = Full("x");
	if (empty.or(7) != 7 || full.or("y") != "x")
		return 6;
	return 42;
}
