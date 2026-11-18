// An instance property whose write is `never` cannot be written ("This expression cannot be accessed for writing").
class Item {
	public var area(get, never):Int;

	public function new() {}

	function get_area():Int
		return 1;
}

class Main {
	static function main() {
		var item = new Item();
		item.area = 3;
	}
}
