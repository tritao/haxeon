class Box {
	public function get():Int {
		return 42;
	}
}

function main():Int {
	var box = new Box();
	return box.get();
}
