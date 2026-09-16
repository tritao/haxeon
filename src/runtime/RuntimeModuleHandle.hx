package runtime;

/** Opaque native handle for one loaded HashLink runtime module generation. */
typedef RuntimeModuleHandle = hl.Abstract<"realtime_module">;

/** Explicit module-owned GC root exposed by the host runtime facade. */
class RuntimeGcHandle {
	final handle:hl.Abstract<"haxeon_gc_handle">;

	function new(handle:hl.Abstract<"haxeon_gc_handle">) {
		this.handle = handle;
	}

	/** Read the currently rooted value. A closed handle reads as null. */
	public inline function get():Dynamic
		return RuntimeGcHandleNative.native_gc_handle_get(handle);

	/** Replace the rooted value. */
	public inline function set(value:Dynamic):Void
		RuntimeGcHandleNative.native_gc_handle_set(handle, cast value);

	/** Expose the current managed object address to an explicitly cooperating native consumer. */
	public inline function raw():hl.Bytes
		return RuntimeGcHandleNative.native_gc_handle_raw(handle);

	/** Unregister the root once. */
	public inline function close():Bool
		return RuntimeGcHandleNative.native_gc_handle_close(handle);

	/** Whether this handle can no longer be read or updated. */
	public inline function isClosed():Bool
		return RuntimeGcHandleNative.native_gc_handle_is_closed(handle);

	@:allow(runtime.LoadedModule)
	static inline function createOwned(value:Dynamic, owner:RuntimeModuleHandle):RuntimeGcHandle
		return new RuntimeGcHandle(RuntimeGcHandleNative.native_gc_handle_create_owned(cast value, owner));
}

/** HashLink-only implementation boundary for host runtime GC interop. */
@:hlNative("haxeon_runtime")
private class RuntimeGcHandleNative {
	public static function native_gc_handle_create_owned(value:Dynamic, owner:RuntimeModuleHandle):hl.Abstract<"haxeon_gc_handle">
		return null;

	public static function native_gc_handle_get(handle:hl.Abstract<"haxeon_gc_handle">):Dynamic
		return null;

	public static function native_gc_handle_set(handle:hl.Abstract<"haxeon_gc_handle">, value:Dynamic):Void {}

	public static function native_gc_handle_raw(handle:hl.Abstract<"haxeon_gc_handle">):hl.Bytes
		return null;

	public static function native_gc_handle_close(handle:hl.Abstract<"haxeon_gc_handle">):Bool
		return false;

	public static function native_gc_handle_is_closed(handle:hl.Abstract<"haxeon_gc_handle">):Bool
		return true;
}
