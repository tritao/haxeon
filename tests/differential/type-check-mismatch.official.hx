// `(value : Type)` checks that the value unifies with the type, as Haxe does: a String is not an Int ("String should be Int").
class Main {
	static function main() {
		var count = ("three":Int);
		Sys.println(count);
	}
}
