package runtime;

/** Lifetime operations for opaque pointers returned through HXI. */
@:hlNative("realtime_runtime")
class NativePointer {
	/** Releases an owned pointer once. Borrowed and already-closed pointers return false. */
	public static function native_pointer_close(pointer:hl.Abstract<"native_pointer">):Bool
		return false;

	/** Reports whether the address has been released or was originally null. */
	public static function native_pointer_is_closed(pointer:hl.Abstract<"native_pointer">):Bool
		return true;
}
