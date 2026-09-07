class Value {
	public final number:Int;

	public function new(number:Int) {
		this.number = number;
	}
}

function requireValue(value:Null<Value>):Value {
	if (value == null)
		throw "missing value";
	return value;
}

function main():Int {
	return requireValue(new Value(42)).number;
}
