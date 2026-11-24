// A named local function is bound as a function, not a variable: Haxe rejects a write to it.
class Main {
	static function main() {
		function step():Int
			return 1;
		step = null;
	}
}
