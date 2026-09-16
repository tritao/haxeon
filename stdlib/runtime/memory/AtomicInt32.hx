package runtime.memory;

/** Atomic operations over one aligned unmanaged i32. */
class AtomicInt32 {
	public final address:RawPtr<Int32>;

	public function new(address:RawPtr<Int32>) {
		if (address.isNull())
			throw "AtomicInt32 requires a non-null address";
		this.address = address;
	}

	public inline function load(?order:MemoryOrder = SeqCst):Int
		return AtomicInt32Native.native_atomic_i32_load(address, MemoryOrderEncoding.encodeLoad(order));

	public inline function store(value:Int, ?order:MemoryOrder = SeqCst):Void
		AtomicInt32Native.native_atomic_i32_store(address, value, MemoryOrderEncoding.encodeStore(order));

	public inline function exchange(value:Int, ?order:MemoryOrder = SeqCst):Int
		return AtomicInt32Native.native_atomic_i32_exchange(address, value, MemoryOrderEncoding.encode(order));

	/** Return the value observed before the compare-exchange operation. */
	public inline function compareExchangeObserved(expected:Int, replacement:Int, ?order:MemoryOrder = SeqCst):Int
		return AtomicInt32Native.native_atomic_i32_compare_exchange(address, expected, replacement, MemoryOrderEncoding.encode(order));

	public inline function compareExchange(expected:Int, replacement:Int, ?order:MemoryOrder = SeqCst):Bool
		return compareExchangeObserved(expected, replacement, order) == expected;

	/** Return the value observed before the addition. */
	public inline function fetchAdd(value:Int, ?order:MemoryOrder = SeqCst):Int
		return AtomicInt32Native.native_atomic_i32_fetch_add(address, value, MemoryOrderEncoding.encode(order));

	public static inline function fence(?order:MemoryOrder = SeqCst):Void
		AtomicInt32Native.native_atomic_fence(MemoryOrderEncoding.encode(order));
}

private class MemoryOrderEncoding {
	public static inline function encode(order:MemoryOrder):Int
		return switch order {
			case Relaxed: 0;
			case Acquire: 1;
			case Release: 2;
			case AcqRel: 3;
			case SeqCst: 4;
		};

	public static inline function encodeLoad(order:MemoryOrder):Int
		return switch order {
			case Release | AcqRel:
				throw "Atomic loads cannot use release ordering";
			case _:
				encode(order);
		};

	public static inline function encodeStore(order:MemoryOrder):Int
		return switch order {
			case Acquire | AcqRel:
				throw "Atomic stores cannot use acquire ordering";
			case _:
				encode(order);
		};
}

@:hlNative("haxeon_runtime")
private class AtomicInt32Native {
	public static function native_atomic_i32_load(address:RawPtr<Int32>, order:Int):Int
		return 0;

	public static function native_atomic_i32_store(address:RawPtr<Int32>, value:Int, order:Int):Void {}

	public static function native_atomic_i32_exchange(address:RawPtr<Int32>, value:Int, order:Int):Int
		return 0;

	public static function native_atomic_i32_compare_exchange(address:RawPtr<Int32>, expected:Int, replacement:Int, order:Int):Int
		return 0;

	public static function native_atomic_i32_fetch_add(address:RawPtr<Int32>, value:Int, order:Int):Int
		return 0;

	public static function native_atomic_fence(order:Int):Void {}
}
