struct NumericBoundaryValue { public final number:Int; public function new(number:Int) this.number = number; }
class NumericBoundary<A, B> {
	public var anchor:A;
	public var value:B;
	public var storage:Array<B>;
	public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = []; }
}
function main():Int {
	var ints = new NumericBoundary<NumericBoundaryValue, Int>(new NumericBoundaryValue(1), 42);
	var intView:NumericBoundary<Dynamic, Dynamic> = ints;
	var rejected = false;
	try intView.value = 1.5 catch (_:Dynamic) rejected = true;
	if (!rejected || ints.value != 42) return 1;
	rejected = false;
	try intView.value = null catch (_:Dynamic) rejected = true;
	if (!rejected || ints.value != 42) return 2;
	intView.value = 7;
	if (ints.value != 7) return 3;
	var floats = new NumericBoundary<NumericBoundaryValue, Float>(new NumericBoundaryValue(1), 4.5);
	var floatView:NumericBoundary<Dynamic, Dynamic> = floats;
	rejected = false;
	try floatView.value = 2 catch (_:Dynamic) rejected = true;
	if (!rejected || floats.value != 4.5) return 4;
	floatView.value = 9.5;
	if (floats.value != 9.5) return 5;
	var flags = new NumericBoundary<NumericBoundaryValue, Bool>(new NumericBoundaryValue(1), true);
	var flagView:NumericBoundary<Dynamic, Dynamic> = flags;
	rejected = false;
	try flagView.value = 1 catch (_:Dynamic) rejected = true;
	if (!rejected || !flags.value) return 6;
	flagView.value = false;
	if (flags.value) return 7;
	var wide = new NumericBoundary<NumericBoundaryValue, haxe.Int64>(new NumericBoundaryValue(1), haxe.Int64.make(1, 3));
	var wideView:NumericBoundary<Dynamic, Dynamic> = wide;
	rejected = false;
	try wideView.value = 3 catch (_:Dynamic) rejected = true;
	if (!rejected || wide.value != haxe.Int64.make(1, 3)) return 8;
	wideView.value = haxe.Int64.make(2, 5);
	if (wide.value != haxe.Int64.make(2, 5)) return 9;
	var optional = new NumericBoundary<NumericBoundaryValue, Null<Int>>(new NumericBoundaryValue(1), null);
	var optionalView:NumericBoundary<Dynamic, Dynamic> = optional;
	optionalView.value = 8;
	if (optional.value != 8) return 10;
	rejected = false;
	try optionalView.value = 8.5 catch (_:Dynamic) rejected = true;
	if (!rejected || optional.value != 8) return 11;
	optionalView.value = null;
	return optional.value == null ? 42 : 12;
}
