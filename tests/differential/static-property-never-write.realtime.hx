// A static property whose write is `never` cannot be written, of an abstract as of a class ("This expression cannot be accessed for
// writing").
abstract Counter(Int) {
	public static var limit(get, never):Int;

	static function get_limit():Int
		return 100;
}

class Main {
	static function main() {
		Counter.limit = 3;
	}
}
