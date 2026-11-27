// Named arguments: after its positional ones, a call names the parameters it passes in their declared order, skipping
// optional ones, which take their defaults. Methods, overrides (whose own defaults fill a skipped parameter), static
// extensions, constructors, generic functions and constructors and enum constructors bind them the same way, and the
// arguments are evaluated in the order written. A struct without a constructor gets a memberwise one, whose defaults are
// its fields' initializers, and `with`, a copy with the named fields replaced.
using namedargs.Padding;

enum Shape {
	Rect(width:Int, ?height:Int, ?label:String);
}

struct Size {
	public final w:Int;
	public final h:Int;

	public function new(w:Int, h:Int = 5) {
		this.w = w;
		this.h = h;
	}
}

struct Props {
	public final key:String;
	public final value:String = "";
	public final enabled:Bool = true;
	public final placeholder:Null<String> = null;
	public final classes:Array<String> = [];
}

struct Point {
	public final x:Float;
	public final y:Float = 0.0;
}

interface Painter {
	function paint(color:String, ?alpha:Float, ?layer:Int):String;
}

class Base implements Painter {
	public function new() {}

	public function paint(color:String, ?alpha:Float = 1.0, ?layer:Int = 0):String
		return color + " " + alpha + " " + layer;

	public function scale(x:Int, y:Int = 2, z:Int = 3):Int
		return x * y * z;
}

class Derived extends Base {
	public function new()
		super();

	override public function paint(color:String, ?alpha:Float = 0.5, ?layer:Int = 9):String
		return "derived " + color + " " + alpha + " " + layer;
}

class Box<T> {
	public final value:T;
	public final count:Int;

	public function new(value:T, label:String = "box", count:Int = 1) {
		this.value = value;
		this.count = count;
	}
}

var order:Array<String> = [];
var made = 0;

function fresh():Props {
	made++;
	return new Props("k", "v");
}

function area(width:Int, height:Int = 3, scale:Int = 1, ?unit:String):String
	return (width * height * scale) + (unit == null ? "" : unit);

function pick<T>(first:T, ?second:T, third:Int = 7):String
	return first + "/" + second + "/" + third;

function note(name:String, value:Int):Int {
	order.push(name);
	return value;
}

function main():Int {
	if (area(2) != "6" || area(2, height:5) != "10" || area(2, scale:10) != "60" || area(width:4, unit:"m") != "12m")
		return 1;
	if (area(2, height:note("h", 3), scale:note("s", 2)) != "12" || order.join(",") != "h,s")
		return 2;
	if (pick("a", third:9) != "a/null/9")
		return 3;
	if (new Base().scale(2, z:5) != 20)
		return 4;
	var painter:Painter = new Derived(), base:Base = new Derived();
	if (painter.paint("red", layer:4) != "derived red 0.5 4" || base.paint("blue", alpha:0.25) != "derived blue 0.25 9")
		return 5;
	if ("x".padded(right:2) != "x.." || "x".padded(1, fill:"-") != "-x")
		return 6;
	switch Rect(3, label:"r") {
		case Rect(w, h, l):
			if (w != 3 || h != null || l != "r")
				return 7;
	}
	var size = new Size(w:4), box = new Box("x", count:4);
	if (size.w != 4 || size.h != 5 || box.value != "x" || box.count != 4)
		return 8;
	var props = new Props("name", placeholder:"Name"), point = new Point(x:3.0);
	if (props.key != "name" || props.value != "" || !props.enabled || props.placeholder != "Name"
		|| props.classes.length != 0
		|| point.x != 3.0 || point.y != 0.0)
		return 9;
	var off = props.with(enabled:false), cleared = props.with(placeholder:null), same = props.with();
	if (off.enabled || off.key != "name" || off.placeholder != "Name" || !props.enabled || cleared.placeholder != null
		|| same.placeholder != "Name")
		return 10;
	var once = fresh().with(value:"w", classes:["a"]);
	if (made != 1 || once.key != "k" || once.value != "w" || once.classes.length != 1)
		return 11;
	return 42;
}
