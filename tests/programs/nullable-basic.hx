class Box {
	public function new() {}
}

function main():Int {
	var empty:Null<Box> = null;
	if (empty == null)
		return 42;

	var present:Null<Box> = new Box();
	if (present == null)
		return 0;
	return 42;
}
