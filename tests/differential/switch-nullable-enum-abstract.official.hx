// A switch over a nullable enum abstract follows Haxe's null rule for enums: the root switch need not match null, a null
// reaches `case null`, a default or a catch-all when the switch has one, and a nullable enum abstract decided on below
// the root (a constructor argument, a tuple element under another element's value) must match null. Matching a declared
// value inside a constructor argument (`Wrap(A)`, `Wrap(B)`) covers that constructor.
// (Haxe 4.3.7 leaves a null subject of a switch without a default unmatched; Haxeon throws "Null access" there, which
// tests/programs/nullable-enum-abstract-switch.hx checks.)
enum abstract Kind(Int) {
	var A = 1;
	var B = 2;
}

enum abstract Name(String) {
	var X = "x";
	var Y = "y";
}

enum Box {
	Wrap(kind:Kind);
	Maybe(kind:Null<Kind>);
	Empty;
}

class Main {
	static function bare(k:Null<Kind>):String
		return switch (k) {
			case A: "A";
			case B: "B";
		};

	static function name(n:Null<Name>):String {
		switch (n) {
			case X:
				return "X";
			case Y:
				return "Y";
		}
	}

	static function withDefault(k:Null<Kind>):String
		return switch (k) {
			case A: "A";
			default: "D";
		};

	static function capture(k:Null<Kind>):String
		return switch (k) {
			case A: "A";
			case other: "other " + other;
		};

	static function withNull(k:Null<Kind>):String
		return switch (k) {
			case A: "A";
			case B: "B";
			case null: "null";
		};

	static function box(b:Box):String
		return switch (b) {
			case Wrap(A): "wrap A";
			case Wrap(B): "wrap B";
			case Maybe(A): "maybe A";
			case Maybe(B): "maybe B";
			case Maybe(null): "maybe null";
			case Empty: "empty";
		};

	static function pair(a:Kind, b:Null<Kind>):String
		return switch [a, b] {
			case [A, _]: "A _";
			case [B, A]: "B A";
			case [B, B]: "B B";
			case [B, null]: "B null";
		};

	static function main() {
		Sys.println([bare(A), bare(B), name(X), name(Y)].join(" "));
		Sys.println([for (k in ([A, B, null]:Array<Null<Kind>>)) withDefault(k) + "/" + capture(k) + "/"
			+ withNull(k)].join(" "));
		Sys.println([for (b in [Wrap(A), Wrap(B), Maybe(A), Maybe(B), Maybe(null), Empty]) box(b)].join(", "));
		Sys.println([for (a in [A, B]) for (b in ([A, B, null]:Array<Null<Kind>>)) pair(a, b)].join(", "));
	}
}
