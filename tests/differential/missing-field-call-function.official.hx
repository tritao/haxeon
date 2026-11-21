// A function value's missing method names its type as Haxe spells a function type without argument names.
class Main {
	static function main() {
		var combine:(Int, String) -> Int = null;
		combine.missing();
	}
}
