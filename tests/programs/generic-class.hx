class Box<T> {
	var value:T;

	public function new(value:T) {
		this.value = value;
	}

	public function get():T
		return value;
}

function main():Int {
	var box:Box<Int> = new Box<Int>(42);
	return box.get();
}
