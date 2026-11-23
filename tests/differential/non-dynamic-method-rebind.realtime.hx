class Main {
	public function new() {}

	function read():Int {
		return 1;
	}

	static function main() {
		var obj = new Main();
		obj.read = () -> 2;
	}
}
