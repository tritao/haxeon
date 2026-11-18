// The value of an assignment used as an expression, as Haxe gives it: the result of the setter where a property's setter stores
// it (`=`, `+=`, `++x`, `--x`; `x++` is the old value), else the value stored, converted to the target's type.
class Item {
	public var p(get, set):Int;
	var store = 0;
	public var readOnlyGetter(get, default):Int = 0;
	public var hidden(null, default):Int = 0;
	public var ratio:Float = 0;
	public var plain = 0;

	public function new() {}

	function get_p() {
		Sys.println("get p");
		return store;
	}

	function set_p(v:Int) {
		Sys.println("set p " + v);
		store = v;
		return v * 10;
	}

	function get_readOnlyGetter() {
		Sys.println("get readOnlyGetter");
		return 99;
	}

	public function inside() {
		Sys.println(p = 4);
		Sys.println(this.p = 5);
		Sys.println(p += 1);
		Sys.println(++p);
		Sys.println(--this.p);
		Sys.println(plain = 8);
	}

	public static var s(get, set):Int;
	static var sstore = 0;

	static function get_s() {
		Sys.println("get s");
		return sstore;
	}

	static function set_s(v:Int) {
		Sys.println("set s " + v);
		sstore = v;
		return v * 100;
	}

	public static function insideStatic() {
		Sys.println(s = 2);
		Sys.println(s -= 1);
		Sys.println(++s);
	}
}

abstract Meters(Array<Int>) {
	public var value(get, set):Int;

	public inline function new() this = [0];

	function get_value() return this[0];

	function set_value(v:Int) {
		this[0] = v;
		return v + 1000;
	}
}

class Main {
	static var made = 0;

	static function make(item:Item):Item {
		made++;
		return item;
	}

	static function main() {
		var o = new Item();
		Sys.println(o.p = 3);
		Sys.println(o.p += 2);
		Sys.println(++o.p);
		Sys.println(--o.p);
		Sys.println(o.p++);
		Sys.println(o.p--);
		var chained = o.p = 7;
		Sys.println(chained);
		Sys.println(make(o).p = 2);
		Sys.println(make(o).p += 2);
		Sys.println(++make(o).p);
		Sys.println(made);
		Sys.println(o.readOnlyGetter = 5);
		Sys.println(o.hidden = 6);
		Sys.println(o.ratio = 1);
		Sys.println(o.plain = 2);
		var a = 0, b = 0;
		Sys.println(a = b = 4);
		Sys.println(a + b);
		Sys.println(a += 3);
		Sys.println(++a);
		var floats = [0.5];
		Sys.println(floats[0] = 2);
		Sys.println(floats[0] += 1);
		var map = ["k" => 1];
		Sys.println(map["k"] = 5);
		var object:Dynamic = {x: 1};
		Sys.println(object.x = 9);
		Sys.println(object.x);
		o.inside();
		Sys.println(Item.s = 3);
		Sys.println(Item.s += 2);
		Sys.println(++Item.s);
		Sys.println(Item.s++);
		Item.insideStatic();
		var m = new Meters();
		Sys.println(m.value = 1);
		Sys.println(m.value += 1);
		Sys.println(++m.value);
		Sys.println(m.value);
		var total = 0;
		for (i in 0...3)
			total += (o.p = i);
		Sys.println(total);
		if ((o.p = 1) > 5)
			Sys.println("setter result compared");
	}
}
