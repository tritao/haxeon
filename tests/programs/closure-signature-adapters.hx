/** Closure casts between signatures of one arity, each adapted through its target's one adapter (wasm32). */
class AdapterReceiver {
	public var base:Int;
	public function new(base:Int) this.base = base;
	public function plus(value:Int):Int return base + value;
}

function twice(value:Int):Int return value * 2;
function half(value:Float):Float return value / 2;
function shout(text:String):String return text + "!";
function apply(callback:Int->Int):Int return callback(20);
function pair(left:Int, right:String):String return right + left;

function main():Int {
	// Int result read as Float.
	var source:Dynamic = twice;
	var asFloat:Int->Float = cast source;
	if (asFloat(3) != 6.0) return 1;
	// A Dynamic call boxes an Int argument for a Float parameter.
	var dynamicHalf:Dynamic = half;
	if (dynamicHalf(5) != 2.5) return 2;
	// String through Dynamic and back.
	var shoutDynamic:Dynamic = shout;
	var erased:Dynamic->Dynamic = cast shoutDynamic;
	if (erased("hi") != "hi!") return 3;
	// A function argument converted on the way in.
	var applyDynamic:Dynamic = apply;
	var applyErased:Dynamic->Dynamic = cast applyDynamic;
	if (applyErased(twice) != 40) return 4;
	// A bound closure, adapted, then cast again to a third signature.
	var bound:Dynamic = new AdapterReceiver(40).plus;
	var boundFloat:Int->Float = cast bound;
	if (boundFloat(2) != 42.0) return 5;
	#if wasm
	// HashLink cannot call an adapter cast again; the Wasm adapter is a closure of its target signature.
	var again:Dynamic = boundFloat;
	var boundDynamic:Dynamic->Dynamic = cast again;
	if (boundDynamic(1) != 41) return 6;
	#end
	// Two arguments of different types.
	var pairDynamic:Dynamic = pair;
	var pairErased:(Dynamic, Dynamic) -> Dynamic = cast pairDynamic;
	if (pairErased(2, "x") != "x2") return 7;
	// The matching signature is the same closure, not an adapter.
	var same:Int->Int = cast source;
	if (same(21) != 42) return 8;
	return 42;
}
