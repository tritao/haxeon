package runtime.memory;

/** Atomic operations over one aligned unmanaged pointer slot. */
class AtomicPointer<T> {
	public final address:RawPtr<RawPtr<T>>;

	public function new(address:RawPtr<RawPtr<T>>) {
		if (address.isNull())
			throw "AtomicPointer requires a non-null address";
		this.address = address;
	}

	public inline function load(?order:MemoryOrder = SeqCst):RawPtr<T>
		return cast AtomicPointerNative.native_atomic_ptr_load(cast address, AtomicOrder.encodeLoad(order));

	public inline function store(value:RawPtr<T>, ?order:MemoryOrder = SeqCst):Void
		AtomicPointerNative.native_atomic_ptr_store(cast address, cast value, AtomicOrder.encodeStore(order));

	public inline function exchange(value:RawPtr<T>, ?order:MemoryOrder = SeqCst):RawPtr<T>
		return cast AtomicPointerNative.native_atomic_ptr_exchange(cast address, cast value, AtomicOrder.encode(order));

	/** Return the value observed before the compare-exchange operation. */
	public inline function compareExchangeObserved(expected:RawPtr<T>, replacement:RawPtr<T>, ?order:MemoryOrder = SeqCst):RawPtr<T>
		return cast AtomicPointerNative.native_atomic_ptr_compare_exchange(cast address, cast expected, cast replacement, AtomicOrder.encode(order));

	public inline function compareExchange(expected:RawPtr<T>, replacement:RawPtr<T>, ?order:MemoryOrder = SeqCst):Bool {
		var observed:RawPtr<T> = cast AtomicPointerNative.native_atomic_ptr_compare_exchange(cast address, cast expected, cast replacement,
			AtomicOrder.encode(order));
		return observed == expected;
	}
}

@:hlNative("haxeon_runtime")
private class AtomicPointerNative {
	public static function native_atomic_ptr_load(address:RawPtr<RawPtr<Dynamic>>, order:Int):RawPtr<Dynamic>
		return RawPtr.nullPtr();

	public static function native_atomic_ptr_store(address:RawPtr<RawPtr<Dynamic>>, value:RawPtr<Dynamic>, order:Int):Void {}

	public static function native_atomic_ptr_exchange(address:RawPtr<RawPtr<Dynamic>>, value:RawPtr<Dynamic>, order:Int):RawPtr<Dynamic>
		return RawPtr.nullPtr();

	public static function native_atomic_ptr_compare_exchange(address:RawPtr<RawPtr<Dynamic>>, expected:RawPtr<Dynamic>, replacement:RawPtr<Dynamic>, order:Int):RawPtr<Dynamic>
		return RawPtr.nullPtr();
}
