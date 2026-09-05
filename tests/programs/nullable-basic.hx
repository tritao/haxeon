class Box {
	public function new() {}

	public function value():Int {
		return 42;
	}
}

function main():Int {
	var empty:Null<Box> = null;
	if (empty == null)
		return 42;

	var present:Null<Box> = new Box();
	if (present == null)
		return 0;
	if (present.value() == 42)
		return 42;
	var maybeText:Null<String> = null;
	if (maybeText == null)
		return 42;
	return 42;
}
