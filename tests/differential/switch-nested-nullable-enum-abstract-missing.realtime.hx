// A nullable enum abstract decided on below the root must match null, as a Null<Enum> must: `Maybe(A)` and `Maybe(B)`
// leave `Maybe(null)`. (Haxe 4.3.7 rejects this by failing with Not_found while naming the missing pattern; Haxeon
// reports E1021 with `Maybe(null)`.)
enum abstract Kind(Int) {
	var A = 1;
	var B = 2;
}

enum Box {
	Maybe(kind:Null<Kind>);
	Empty;
}

class Main {
	static function box(b:Box):String
		return switch (b) {
			case Maybe(A): "A";
			case Maybe(B): "B";
			case Empty: "empty";
		};

	static function main() {
		Sys.println(box(Empty));
	}
}
