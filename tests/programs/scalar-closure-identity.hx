struct ClosureIdentityValue {
	public final number:Int;
	public function new(number:Int) this.number = number;
}

class ClosureIdentityOwner {
	public final offset:Int;
	public function new(offset:Int) this.offset = offset;
	public function apply(value:ClosureIdentityValue):ClosureIdentityValue return new ClosureIdentityValue(value.number + offset);
}

function scalarIdentity(value:ClosureIdentityValue):ClosureIdentityValue return value;
function dynamicIdentity(value:Dynamic):Dynamic return value;

class ScalarClosureIdentityCensus {
	static var typed:ClosureIdentityValue->ClosureIdentityValue;
	static var erased:Dynamic;
	static var source:ClosureIdentityValue->ClosureIdentityValue;
	static var genuine:Dynamic;
	public static function prepare():Void {
		source = scalarIdentity;
		erased = source;
		genuine = dynamicIdentity;
		typed = cast genuine;
	}
	public static function perform(n:Int):Int {
		for (_ in 0...n) {
			var restored:ClosureIdentityValue->ClosureIdentityValue = cast erased;
			var unwrapped:Dynamic = typed;
			if (restored != source || unwrapped != genuine) return -1;
		}
		return n;
	}
}

function main():Int {
	var original:ClosureIdentityValue->ClosureIdentityValue = scalarIdentity;
	var value:Dynamic = original;
	var restored:ClosureIdentityValue->ClosureIdentityValue = cast value;
	if (restored != original) return 1;
	for (_ in 0...1000) { value = restored; restored = cast value; }
	if (restored != original || restored(new ClosureIdentityValue(42)).number != 42) return 3;
	var owner = new ClosureIdentityOwner(2), method:ClosureIdentityValue->ClosureIdentityValue = owner.apply;
	var escaped:Dynamic = method, returned:ClosureIdentityValue->ClosureIdentityValue = cast escaped;
	if (returned != method || returned(new ClosureIdentityValue(40)).number != 42) return 4;
	var genuine:Dynamic = dynamicIdentity;
	var view:ClosureIdentityValue->ClosureIdentityValue = cast genuine;
	var roundTrip:Dynamic = view;
	if (roundTrip != genuine) return 5;
	for (_ in 0...1000) { view = cast roundTrip; roundTrip = view; }
	if (roundTrip != genuine) return 6;
	var missing:ClosureIdentityValue->ClosureIdentityValue = null, missingDynamic:Dynamic = missing;
	var missingRestored:ClosureIdentityValue->ClosureIdentityValue = cast missingDynamic;
	if (missingRestored != null || missingDynamic != null) return 7;
	ScalarClosureIdentityCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	if (ScalarClosureIdentityCensus.perform(8) != 8 || ScalarClosureIdentityCensus.perform(1024) != 1024) return 8;
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 9;
	#end
	return 42;
}
