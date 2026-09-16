package runtime.memory;

/** Atomic operations over one aligned unmanaged signed i64. */
class AtomicInt64 {
	public final address:RawPtr<Int64>;

	public function new(address:RawPtr<Int64>) {
		if (address.isNull())
			throw "AtomicInt64 requires a non-null address";
		this.address = address;
	}

	public inline function load(?order:MemoryOrder = SeqCst):Int64
		return AtomicInt64Native.native_atomic_i64_load(address, AtomicOrder.encodeLoad(order));

	public inline function store(value:Int64, ?order:MemoryOrder = SeqCst):Void
		AtomicInt64Native.native_atomic_i64_store(address, value, AtomicOrder.encodeStore(order));

	public inline function exchange(value:Int64, ?order:MemoryOrder = SeqCst):Int64
		return AtomicInt64Native.native_atomic_i64_exchange(address, value, AtomicOrder.encode(order));

	/** Return the value observed before the compare-exchange operation. */
	public inline function compareExchangeObserved(expected:Int64, replacement:Int64, ?order:MemoryOrder = SeqCst):Int64
		return AtomicInt64Native.native_atomic_i64_compare_exchange(address, expected, replacement, AtomicOrder.encode(order));

	public inline function compareExchange(expected:Int64, replacement:Int64, ?order:MemoryOrder = SeqCst):Bool
		return compareExchangeObserved(expected, replacement, order) == expected;

	/** Return the value observed before the addition. */
	public inline function fetchAdd(value:Int64, ?order:MemoryOrder = SeqCst):Int64
		return AtomicInt64Native.native_atomic_i64_fetch_add(address, value, AtomicOrder.encode(order));

	public static inline function fence(?order:MemoryOrder = SeqCst):Void
		AtomicInt64Native.native_atomic_fence(AtomicOrder.encode(order));
}

@:hlNative("haxeon_runtime")
private class AtomicInt64Native {
	public static function native_atomic_i64_load(address:RawPtr<Int64>, order:Int):Int64
		return 0;

	public static function native_atomic_i64_store(address:RawPtr<Int64>, value:Int64, order:Int):Void {}

	public static function native_atomic_i64_exchange(address:RawPtr<Int64>, value:Int64, order:Int):Int64
		return 0;

	public static function native_atomic_i64_compare_exchange(address:RawPtr<Int64>, expected:Int64, replacement:Int64, order:Int):Int64
		return 0;

	public static function native_atomic_i64_fetch_add(address:RawPtr<Int64>, value:Int64, order:Int):Int64
		return 0;

	public static function native_atomic_fence(order:Int):Void {}
}
