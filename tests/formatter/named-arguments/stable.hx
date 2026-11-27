enum Shape {
	Circle(radius:Float);
	Rect(width:Float, height:Float = 1.0);
}

class Probe {
	static function area(width:Float, ?height:Float, scale:Float = 1.0):Float return width;

	static function main() {
		var f = new TextField("name", value, placeholder: "Name", onSubmit: _ -> add());
		var g = area(2.0, scale: 3.0);
		var c = Rect(width: 2.0, height: 3.0);
		var p = props.with(enabled: false);
		var h = (a:Int) -> a + 1;
		var t:(Int, Int) -> Int = null;
		var n = new Pair<Int>(first: 1, second: 2);
	}
}
