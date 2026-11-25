// An enum's per-case constants: each case sets them in a block after its payload, a default covers a case that sets none,
// and a read is the case's value, through a value, a case or `this` (docs/design/ENUM_MEMBERS.md).
enum ParameterType {
	/** How many numbers a parameter takes. */
	public final components:Int;
	public final label:String;
	public final vector:Bool = true;
	public final scale:Float = 1.0;

	Scalar {components: 1, label: "float", vector: false};
	Pair {components: 2, label: "vec" + "2", scale: 0.5};
	Quad {components: 4, label: "vec4"};

	public function bytes():Int
		return components * 4;

	public static function widest():ParameterType {
		var best = Scalar;
		for (type in [Scalar, Pair, Quad])
			if (type.components > best.components)
				best = type;
		return best;
	}
}

enum Shape {
	public final sides:Int = -1;
	public final kind:ParameterType = Scalar;
	public final name:Null<String> = null;

	Circle(radius:Float) {sides: 0, name: "circle"};
	Square(side:Float) {sides: 4, kind: ParameterType.Pair};
	Polygon(points:Array<Float>);
}

enum Slot<T> {
	public final filled:Bool;

	Empty {filled: false};
	Full(value:T) {filled: true};
}

// A case named as a type in scope is still the case where its constants are read.
class Paint {
	public function new() {}
}

enum Fill {
	public final layers:Int;

	Paint {layers: 2};
	None {layers: 0};
}

function main():Int {
	if (Pair.components != 2 || Scalar.label != "float" || Pair.label != "vec2" || Quad.scale != 1.0
		|| Pair.scale != 0.5)
		return 1;
	var type:ParameterType = Quad;
	if (type.bytes() != 16 || !type.vector || Scalar.vector || ParameterType.widest() != Quad)
		return 2;
	var total = 0;
	for (shape in [Circle(1.0), Square(2.0), Polygon([])])
		total += shape.sides;
	if (total != 3)
		return 3;
	if (Square(1.0).kind != Pair || Circle(1.0).kind != Scalar || Circle(1.0).name != "circle"
		|| Polygon([]).name != null)
		return 4;
	var empty:Slot<Int> = Empty, full:Slot<String> = Full("x");
	if (empty.filled || !full.filled)
		return 5;
	var fill:Fill = Paint;
	if (fill.layers != 2 || Fill.None.layers != 0 || new Paint() == null)
		return 6;
	return 42;
}
