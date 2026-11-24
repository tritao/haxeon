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

enum AdapterColor {
	Red;
	Green;
	Blue;
}

// Each source shares one argument and its result with the target and differs in the first argument, so the shared
// values cross the adapter through Dynamic. Float32 is not yet a runtime value type, so no closure can take one.
function sharedBytes(first:Int, value:haxe.io.Bytes):haxe.io.Bytes return value.length == first ? value : null;
function sharedRaw(first:Int, value:hl.Bytes):hl.Bytes return first == 1 ? value : null;
function sharedAbstract(first:Int, value:hl.Abstract<"adapter_handle">):hl.Abstract<"adapter_handle"> return first == 1
	? value : null;
function sharedTag(first:Int, value:AdapterColor):AdapterColor return first == 1 ? value : Red;
function sharedInt64(first:Int, value:haxe.Int64):haxe.Int64 return value + first;

function sharedTypes():Int {
	var bytes = haxe.io.Bytes.alloc(3);
	bytes.set(1, 7);
	var dynamicBytes:Dynamic = sharedBytes;
	var bytesView:(Dynamic, haxe.io.Bytes) -> haxe.io.Bytes = cast dynamicBytes;
	var bytesResult = bytesView(3, bytes);
	if (bytesResult != bytes || bytesResult.get(1) != 7) return 20;
	// Wasm GC has no raw view of Bytes yet.
	#if !wasmgc
	var raw:hl.Bytes = bytes.getData();
	var dynamicRaw:Dynamic = sharedRaw;
	var rawView:(Dynamic, hl.Bytes) -> hl.Bytes = cast dynamicRaw;
	var rawResult = rawView(1, raw);
	if (rawResult != raw || rawView(2, raw) != null) return 21;
	#end
	var dynamicAbstract:Dynamic = sharedAbstract;
	var abstractView:(Dynamic, hl.Abstract<"adapter_handle">) -> hl.Abstract<"adapter_handle"> = cast dynamicAbstract;
	if (abstractView(1, null) != null) return 22;
	var dynamicTag:Dynamic = sharedTag;
	var tagView:(Dynamic, AdapterColor) -> AdapterColor = cast dynamicTag;
	if (tagView(1, Blue) != Blue || tagView(2, Green) != Red) return 23;
	var dynamicInt64:Dynamic = sharedInt64;
	var int64View:(Dynamic, haxe.Int64) -> haxe.Int64 = cast dynamicInt64;
	var big = haxe.Int64.make(1, 5);
	var int64Result = int64View(2, big);
	if (int64Result.high != 1 || int64Result.low != 7) return 24;
	return 42;
}

function main():Int {
	var shared = sharedTypes();
	if (shared != 42) return shared;
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
