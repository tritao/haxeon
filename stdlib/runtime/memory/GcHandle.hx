package runtime.memory;

import runtime.memory.RawPtr;

/** Explicit GC root for a managed value referenced by native runtime state. */
abstract GcHandle<T>(hl.Abstract<"haxeon_gc_handle">) {
	/** Register value as a GC root and return its stable native handle. */
	public static inline function create<T>(value:T):GcHandle<T>
		return cast GcHandleNative.native_gc_handle_create(cast value);

	/** Register value as a root owned by one HashLink runtime module. */
	public static inline function createOwned<T>(value:T, owner:hl.Abstract<"realtime_module">):GcHandle<T>
		return cast GcHandleNative.native_gc_handle_create_owned(cast value, owner);

	/** Read the currently rooted value. A closed handle reads as null. */
	public inline function get():T
		return cast GcHandleNative.native_gc_handle_get(cast this);

	/** Replace the rooted value. */
	public inline function set(value:T):Void
		GcHandleNative.native_gc_handle_set(cast this, cast value);

	/** Expose the current managed object address to an explicitly cooperating native consumer. */
	public inline function raw():RawPtr<UInt8>
		return GcHandleNative.native_gc_handle_raw(cast this);

	/** Unregister the root once. */
	public inline function close():Bool
		return GcHandleNative.native_gc_handle_close(cast this);

	/** Whether this handle can no longer be read or updated. */
	public inline function isClosed():Bool
		return GcHandleNative.native_gc_handle_is_closed(cast this);

}

/** HashLink-only implementation boundary for explicit GC interop. */
@:hlNative("haxeon_runtime")
private class GcHandleNative {
	public static function native_gc_handle_create(value:Dynamic):hl.Abstract<"haxeon_gc_handle">
		return null;

	public static function native_gc_handle_create_owned(value:Dynamic, owner:hl.Abstract<"realtime_module">):hl.Abstract<"haxeon_gc_handle">
		return null;

	public static function native_gc_handle_get(handle:hl.Abstract<"haxeon_gc_handle">):Dynamic
		return null;

	public static function native_gc_handle_set(handle:hl.Abstract<"haxeon_gc_handle">, value:Dynamic):Void {}

	public static function native_gc_handle_raw(handle:hl.Abstract<"haxeon_gc_handle">):RawPtr<UInt8>
		return RawPtr.nullPtr();

	public static function native_gc_handle_close(handle:hl.Abstract<"haxeon_gc_handle">):Bool
		return false;

	public static function native_gc_handle_is_closed(handle:hl.Abstract<"haxeon_gc_handle">):Bool
		return true;

}
