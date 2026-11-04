package haxeon.reactive;

/** Hashes are hints only; every collision is checked by reference identity. */
class ReactiveHash {
	#if wasm
	static var state:Int = 0x6d2b79f5;
	@:allow(haxeon.reactive.ReactiveSource)
	static function next(source:ReactiveSource):Int {
		var value = state;
		value ^= value << 13;
		value ^= value >>> 17;
		value ^= value << 5;
		return state = value;
	}
	#else
	@:allow(haxeon.reactive.ReactiveSource)
	static inline function next(source:ReactiveSource):Int return reactiveHash(source);
	#end
}

#if !wasm
@:hlNative("haxeon_runtime", "__reactive_hash")
extern function reactiveHash(source:Dynamic):Int;
#end
