// A property declared `never` for writing cannot be written: "This expression cannot be accessed for writing".
abstract Stack(Array<Int>) from Array<Int> {
	public var length(get, never):Int;

	function get_length():Int
		return this.length;
}

class Main {
	static function main() {
		var stack:Stack = [1, 2];
		stack.length = 0;
	}
}
