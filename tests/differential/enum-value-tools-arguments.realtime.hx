// Haxe's EnumValueTools.getName takes no argument besides the value it extends.
enum Color {
	Red;
}

class Main {
	static function main() {
		trace(Red.getName(1));
	}
}
