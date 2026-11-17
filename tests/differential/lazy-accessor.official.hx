class Box {
	public var size(get, set):Int;
	public var label(get, never):String;

	var stored = 2;

	public function new() {}

	function get_size() return stored;

	function set_size(value) {
		stored = value * 2;
		return stored;
	}

	function get_label() return "box of " + stored;
}

class Main {
	static function main() {
		var box = new Box();
		Sys.println(box.size);
		box.size = 5;
		Sys.println(box.size);
		Sys.println(box.label);
	}
}
