// A static method the class does not have is missing from `Class<Tools>`, as Haxe reports it.
class Tools {
	public static function run():Int
		return 1;
}

class Main {
	static function main() {
		Tools.walk();
	}
}
