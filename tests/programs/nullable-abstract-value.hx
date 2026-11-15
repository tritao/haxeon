import haxeon.Equality;
struct NullableControlValue implements Equatable {
	public var x:Int;
	public function new(x:Int) this.x = x;
	public function equals(other:NullableControlValue):Bool return x == other.x;
}
abstract NullableControlWrap(NullableControlValue) {
	public function new(x:Int) this = new NullableControlValue(x);
}
function main():Int {
	var absent:Null<NullableControlWrap>= null, absentAgain:Null<NullableControlWrap>= null;
	var present:Null<NullableControlWrap>= new NullableControlWrap(7);
	try {
		if (!Equality.equals(absent, absentAgain)) return 1;
	} catch (_:Dynamic) return 11;
	try {
		if (Equality.equals(absent, present)) return 2;
	} catch (_:Dynamic) return 12;
	try {
		if (Equality.equals(present, absent)) return 3;
	} catch (_:Dynamic) return 13;
	return 42;
}
