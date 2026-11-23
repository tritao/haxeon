class Box {
	public function new() {}

	public function iterator():Iterator<Int>
		return [1].iterator();
}

class Main {
	static function main() {
		for (key => value in new Box())
			trace(key);
	}
}
