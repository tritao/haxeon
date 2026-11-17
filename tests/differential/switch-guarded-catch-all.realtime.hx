// A catch-all arm with a guard (`case _ if ...`, `case v if ...`) in a switch expression matches only when its guard
// holds; later arms see the values it lets through.
class Main {
	static function classify(n:Int):String
		return switch (n) {
			case 1: "one";
			case _ if (n > 5): "big";
			case v if (v < 0): "negative " + v;
			case _: "other";
		};

	static function name(s:String):String
		return switch (s) {
			case "a": "A";
			case other if (other.length > 2): "long " + other;
			default: "short " + s;
		};

	static function main() {
		Sys.println([for (n in [1, 9, -3, 3]) classify(n)].join(", "));
		Sys.println([for (s in ["a", "abc", "bc"]) name(s)].join(", "));
	}
}
