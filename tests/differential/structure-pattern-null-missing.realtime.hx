// `case null` matches the null subject, but the fields of a value still need their cases: Square is unmatched.
enum Shape {
	Circle(radius:Int);
	Square;
}

class Main {
	static function main():Void {
		var item:Null<{shape:Shape}> = {shape: Square};
		var label = switch item {
			case null: "missing";
			case {
				shape:Circle(_)
			}
			: "circle";
		};
		Sys.println(label);
	}
}
