package runtime.memory;

/** Sequentially-consistent atomic operations over one aligned unmanaged i32. */
class AtomicInt32 {
	public final address:RawPtr<Int32>;

	public function new(address:RawPtr<Int32>) {
		if (address.isNull())
			throw "AtomicInt32 requires a non-null address";
		this.address = address;
	}

	public inline function load():Int
		return AtomicInt32Native.native_atomic_i32_load(address);

	public inline function store(value:Int):Void
		AtomicInt32Native.native_atomic_i32_store(address, value);

	public inline function exchange(value:Int):Int
		return AtomicInt32Native.native_atomic_i32_exchange(address, value);

	/** Return the value observed before the compare-exchange operation. */
	public inline function compareExchangeObserved(expected:Int, replacement:Int):Int
		return AtomicInt32Native.native_atomic_i32_compare_exchange(address, expected, replacement);

	public inline function compareExchange(expected:Int, replacement:Int):Bool
		return compareExchangeObserved(expected, replacement) == expected;

	/** Return the value observed before the addition. */
	public inline function fetchAdd(value:Int):Int
		return AtomicInt32Native.native_atomic_i32_fetch_add(address, value);

	public static inline function fence():Void
		AtomicInt32Native.native_atomic_fence();
}

@:hlNative("haxeon_runtime")
private class AtomicInt32Native {
	public static function native_atomic_i32_load(address:RawPtr<Int32>):Int
		return 0;

	public static function native_atomic_i32_store(address:RawPtr<Int32>, value:Int):Void {}

	public static function native_atomic_i32_exchange(address:RawPtr<Int32>, value:Int):Int
		return 0;

	public static function native_atomic_i32_compare_exchange(address:RawPtr<Int32>, expected:Int, replacement:Int):Int
		return 0;

	public static function native_atomic_i32_fetch_add(address:RawPtr<Int32>, value:Int):Int
		return 0;

	public static function native_atomic_fence():Void {}
}
