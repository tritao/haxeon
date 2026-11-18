// Instance properties of a class, as Haxe types them: a `get`, `set` or `dynamic` side calls its accessor (an override's, through
// a base class), inside that side's own accessor `this`'s property is the variable (`@:isVar`), a read in a setter still calls the
// getter, and `null` sides are written from the class and its subclasses.
class Base {
	public var area(get, never):Int;
	public var label(get, set):String;
	var storedLabel = "base";
	public var count(default, null):Int = 0;
	public var plain(default, default):Int = 5;
	public var dyn(dynamic, dynamic):Int;
	@:isVar public var cached(get, set):Int = 7;
	public var sink(never, set):Int;
	public var sunk = 0;
	public var hidden(null, default):Int = 11;

	public function new() {}

	function get_area():Int
		return 10;

	function get_label():String
		return "label:" + storedLabel;

	function set_label(value:String):String {
		storedLabel = value;
		return value;
	}

	function get_cached():Int
		return cached + 1;

	function set_cached(value:Int):Int {
		cached = value * 2;
		return cached;
	}

	function set_sink(value:Int):Int {
		sunk += value;
		return value;
	}

	function get_dyn():Int
		return 42;

	function set_dyn(value:Int):Int {
		sunk = value;
		return value;
	}

	public function bump():Int {
		count++;
		count += 2;
		++count;
		return hidden;
	}

	public function selfUpdate():String {
		cached++;
		cached += 1;
		label = "self";
		label += "!";
		this.sink = 1;
		return label + " " + cached + " " + area;
	}

	public function other(that:Base):Int
		return that.cached;
}

class Derived extends Base {
	override function get_area():Int
		return 20 + super.get_area();

	override function set_label(value:String):String
		return super.set_label(value.toUpperCase());

	public function reset():Void {
		count = 0;
		hidden = 1;
	}
}

class Main {
	static function main() {
		var b = new Base();
		Sys.println("" + b.area + ", " + b.label + ", " + b.count + ", " + b.plain + ", " + b.cached);
		b.label = "x";
		Sys.println("" + b.label);
		b.cached = 3;
		Sys.println("" + b.cached);
		b.cached += 1;
		Sys.println("" + b.cached);
		b.cached++;
		Sys.println("" + b.cached);
		b.cached--;
		Sys.println("" + b.cached);
		var post = b.cached++;
		Sys.println("" + post + ", " + b.cached);
		var pre = ++b.cached;
		Sys.println("" + pre + ", " + b.cached);
		b.sink = 4;
		Sys.println("" + b.sunk);
		Sys.println("" + b.bump() + ", " + b.count);
		b.plain += 5;
		b.plain++;
		Sys.println("" + b.plain);
		Sys.println("" + b.dyn);
		b.dyn = 9;
		Sys.println("" + b.sunk);
		b.label += "!";
		Sys.println("" + b.label);
		Sys.println("" + b.selfUpdate());
		Sys.println("" + b.other(new Base()));
		var d = new Derived();
		Sys.println("" + d.area);
		d.label = "lower";
		Sys.println("" + d.label);
		var asBase:Base = d;
		Sys.println("" + asBase.area);
		asBase.label = "via base";
		Sys.println("" + asBase.label);
		d.bump();
		d.reset();
		Sys.println("" + d.count + ", " + d.bump());
		var items = [new Base(), new Derived()];
		for (item in items) {
			item.cached++;
			Sys.println("" + item.area + ", " + item.cached);
		}
	}
}
