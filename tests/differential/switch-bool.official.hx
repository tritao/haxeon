// A switch over Bool or Null<Bool>, as a statement and as an expression, with guards, captures and defaults. Haxe needs
// no `case null` for the subject: a null reaches `case null`, a default or an unguarded catch-all when the switch has one,
// and otherwise reads as false (HashLink's `if (subject)`).
enum Flag {
	Set(value:Bool);
	Maybe(value:Null<Bool>);
	Unset;
}

class Main {
	static function both(b:Bool):String
		return switch (b) {
			case true: "T";
			case false: "F";
		};

	static function reversed(b:Null<Bool>):String
		return switch (b) {
			case false: "F";
			case true: "T";
		};

	static function withDefault(b:Null<Bool>):String
		return switch (b) {
			case true: "T";
			default: "D";
		};

	static function falseOrDefault(b:Null<Bool>):String
		return switch (b) {
			case false: "F";
			default: "D";
		};

	static function capture(b:Null<Bool>):String
		return switch (b) {
			case false: "F";
			case v: "V" + v;
		};

	static function withNull(b:Null<Bool>):String
		return switch (b) {
			case true: "T";
			case false: "F";
			case null: "N";
		};

	static function guarded(b:Null<Bool>, n:Int):String
		return switch (b) {
			case true if (n > 0): "T+";
			case false if (n > 0): "F+";
			case true: "T";
			case false: "F";
		};

	static function guardedCatchAll(b:Null<Bool>, n:Int):String
		return switch (b) {
			case true: "T";
			case _ if (n > 0): "G";
			case false: "F";
		};

	static function coveredThenDefault(b:Null<Bool>):String
		return switch (b) {
			case false: "F";
			case true: "T";
			case _: "D";
		};

	static function either(b:Bool):String
		return switch (b) {
			case true | false: "TF";
		};

	static function statement(b:Null<Bool>):String {
		switch (b) {
			case true:
				return "sT";
			case false:
				return "sF";
		}
	}

	static function counted(b:Bool):Int {
		var n = 0;
		switch (b) {
			case true:
				n = 1;
			case false:
		}
		return n;
	}

	static function flag(f:Flag):String
		return switch (f) {
			case Set(true): "set";
			case Set(false): "clear";
			case Maybe(true): "maybe set";
			case Maybe(false) | Maybe(null): "maybe not";
			case Unset: "unset";
		};

	static function pair(a:Bool, b:Null<Bool>):String
		return switch [a, b] {
			case [true, true]: "TT";
			case [true, _]: "T_";
			case [false, null]: "FN";
			case [false, true]: "FT";
			case [false, false]: "FF";
		};

	static function main() {
		var values:Array<Null<Bool>> = [true, false, null];
		for (v in values)
			Sys.println([
				reversed(v), withDefault(v), falseOrDefault(v), capture(v), withNull(v), guarded(v, 1), guarded(v, 0),
				guardedCatchAll(v, 1), guardedCatchAll(v, 0), coveredThenDefault(v), statement(v)
			].join(" "));
		Sys.println([
			both(true),
			both(false),
			either(true),
			either(false),
			Std.string(counted(true)),
			Std.string(counted(false))
		].join(" "));
		Sys.println([for (f in [Set(true), Set(false), Maybe(true), Maybe(false), Maybe(null), Unset]) flag(f)]
			.join(", "));
		Sys.println([for (a in [true, false]) for (b in values) pair(a, b)].join(" "));
		var tally = 0;
		for (i in 0...5)
			switch (i % 2 == 0) {
				case true:
					tally += 10;
				case false:
					tally += 1;
			}
		Sys.println(tally);
	}
}
