package runtime.memory;

/**
	Non-owning GC reference for caches and metadata side tables.
	The target is observed while reachable and is cleared after a collection
	when no strong reference keeps it alive.
*/
abstract WeakRoot<T>(hl.Abstract<"haxeon_gc_weak_handle">) {
	/** Register a value without keeping the value alive. */
	public static inline function create<T>(value:T):WeakRoot<T>
		return cast WeakRootNative.native_gc_weak_handle_create(cast value);

	/** Read the target, or null after the collector clears this weak root. */
	public inline function get():Null<T>
		return cast WeakRootNative.native_gc_weak_handle_get(cast this);

	/** Replace the weak target without changing its non-owning semantics. */
	public inline function set(value:T):Void
		WeakRootNative.native_gc_weak_handle_set(cast this, cast value);

	/** Expose the target address only while it remains reachable. */
	public inline function raw():RawPtr<UInt8>
		return WeakRootNative.native_gc_weak_handle_raw(cast this);

	/** Remove the weak slot. Repeated close calls are harmless. */
	public inline function close():Bool
		return WeakRootNative.native_gc_weak_handle_close(cast this);

	/** Whether this weak root has been explicitly closed or finalized. */
	public inline function isClosed():Bool
		return WeakRootNative.native_gc_weak_handle_is_closed(cast this);
}

/** HashLink-only implementation boundary for weak GC interop. */
@:hlNative("haxeon_runtime")
private class WeakRootNative {
	public static function native_gc_weak_handle_create(value:Dynamic):hl.Abstract<"haxeon_gc_weak_handle">
		return null;

	public static function native_gc_weak_handle_get(handle:hl.Abstract<"haxeon_gc_weak_handle">):Dynamic
		return null;

	public static function native_gc_weak_handle_set(handle:hl.Abstract<"haxeon_gc_weak_handle">, value:Dynamic):Void {}

	public static function native_gc_weak_handle_raw(handle:hl.Abstract<"haxeon_gc_weak_handle">):RawPtr<UInt8>
		return RawPtr.nullPtr();

	public static function native_gc_weak_handle_close(handle:hl.Abstract<"haxeon_gc_weak_handle">):Bool
		return false;

	public static function native_gc_weak_handle_is_closed(handle:hl.Abstract<"haxeon_gc_weak_handle">):Bool
		return true;
}
