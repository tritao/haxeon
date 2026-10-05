class Box {
	final value:Int;

	public function new(value:Int)
		this.value = value;

	public function answer():Int
		return value;
}

function main():Int {
	var box = new Box(1);
	box = new Box(40);
	var read = () -> box.answer();
	if (read() != 40)
		return 1;
	box = new Box(41);
	if (read() != 41)
		return 2;
	var f = () -> 0;
	f = () -> 1;
	var call = () -> f();
	if (call() != 1)
		return 3;
	f = () -> 2;
	return read() + call() - 1;
}
