import haxeon.Equality;
struct GenericNullableValue implements Equatable {
	public var x:Int;
	public function new(x:Int) this.x = x;
	public function equals(other:GenericNullableValue):Bool return x == other.x;
}
abstract NullableInner<T>(T) {
	public function new(value:T) this = value;
}
abstract NullableOuter<T>(NullableInner<T>) {
	public function new(value:T) this = new NullableInner<T>(value);
}
function main():Int {
	var none:Null<NullableOuter<GenericNullableValue>>= null, alsoNone:Null<NullableOuter<GenericNullableValue>>= null;
	var some:Null<NullableOuter<GenericNullableValue>>=
		new NullableOuter<GenericNullableValue>(new GenericNullableValue(7));
	if (!Equality.equals(none,
		alsoNone) || Equality.equals(none, some) || Equality.equals(some, none) || !Equality.equals(some,
		some)) return 1;
	return 42;
}
