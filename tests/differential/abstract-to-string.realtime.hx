// An abstract's `toString` is called where the abstract is the static type and a value becomes a String: concatenation,
// interpolation and Std.string, private or not, with null for a nullable one that holds none. A value passed as Dynamic,
// held in an array or converted through a type parameter prints its underlying value, as in Haxe.
abstract Cents(Int) from Int {
	public function toString():String
		return "$" + this;
}

abstract Name(String) from String {
	function toString():String
		return "<" + this + ">";
}

enum abstract Level(Int) {
	var Low = 1;
	var High = 2;

	public function toString():String
		return this == 1 ? "low" : "high";
}

class Main {
	static var calls = 0;

	static function show<T>(v:T):String
		return "" + v;

	static function counted():Null<Cents> {
		calls++;
		return 7;
	}

	static function main() {
		var c:Cents = 5;
		Sys.println("" + c);
		Sys.println('$c');
		Sys.println(Std.string(c));
		Sys.println(c);
		var d:Dynamic = c;
		Sys.println(d);
		Sys.println([c]);
		var l = High;
		Sys.println("" + l);
		Sys.println('${l}');
		Sys.println(Std.string(Low));
		Sys.println(c + "x");
		var n:Null<Cents> = c;
		Sys.println("" + n);
		Sys.println(Std.string(n));
		n = null;
		Sys.println("" + n);
		var s:Null<Name> = null;
		Sys.println("" + s);
		var m:Name = "x";
		Sys.println("" + m);
		Sys.println(show((5:Cents)));
		Sys.println(["a" + (3:Cents), '${(4 : Cents)}!'].join(","));
		Sys.println("" + counted() + " after " + calls + " call");
	}
}
