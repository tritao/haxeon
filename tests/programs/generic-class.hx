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
	var text:Box<String> = new Box<String>("shared layout");
	box.value = 40;
	return box.get() + (text.get() == "shared layout" ? 2 : 0);
}
