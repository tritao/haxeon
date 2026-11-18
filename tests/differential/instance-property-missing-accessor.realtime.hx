// An accessor an instance property names must be declared ("Method get_area required by property area is missing").
class Item {
	public var area(get, never):Int;

	public function new() {}
}

class Main {
	static function main() {
		trace(new Item().area);
	}
}
