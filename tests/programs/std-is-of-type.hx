class Value {
	public function new() {}
}

function main():Int {
	var text:Dynamic = "value",
		number:Dynamic = 42,
		values:Dynamic = [1, 2],
		object:Dynamic = new Value();
	return Std.isOfType(text, String) && !Std.isOfType(text, Int) && Std.isOfType(number, Int) && Std.isOfType(values, Array)
		&& Std.isOfType(object, Value) && !Std.isOfType(null, Value) ? 42 : 1;
}
