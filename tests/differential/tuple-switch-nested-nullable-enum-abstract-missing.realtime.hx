// A nullable enum abstract tuple element matched by value under another element's value must match null too:
// `[B, A]` and `[B, B]` leave `[B, null]`. (Haxe 4.3.7 rejects this by failing with Not_found while naming the missing
// pattern; Haxeon reports E1021 with `[B, null]`.)
enum abstract Kind(Int) {
	var A = 1;
	var B = 2;
}

class Main {
	static function pair(a:Kind, b:Null<Kind>):String
		return switch [a, b] {
			case [A, _]: "A _";
			case [B, A]: "B A";
			case [B, B]: "B B";
		};

	static function main() {
		Sys.println(pair(A, null));
	}
}
