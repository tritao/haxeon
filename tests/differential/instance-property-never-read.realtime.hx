// An instance property whose read is `never` cannot be read ("This expression cannot be accessed for reading").
class Item {
	public var sink(never, set):Int;

	public function new() {}

	function set_sink(value:Int):Int
		return value;
}

class Main {
	static function main() {
		var item = new Item();
		trace(item.sink);
	}
}
