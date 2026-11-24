class Main {
	static function main() {
		var values = [1, 2].iterator();
		for (key => value in values)
			trace(key);
	}
}
