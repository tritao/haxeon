// Two private structs: one nothing constructs and nothing else mentions, one that is constructed and compared through Dynamic. The Dynamic equality
// dispatcher exists because of the second; it must not name the first, and every class it does name must be in the module written for the build.
private struct UnconstructedPoint {
	public final x:Int;
	public function new(x:Int) this.x = x;
}

private struct UsedValue implements Equatable {
	public final value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:UsedValue):Bool return value == other.value;
}

function main():Int {
	var first:Dynamic = new UsedValue(42);
	var second:Dynamic = new UsedValue(42);
	return first == second ? 42 : 0;
}
