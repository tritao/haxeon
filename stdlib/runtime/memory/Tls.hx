package runtime.memory;

import runtime.memory.TlsNative;

/** Thread-local value slot. GC-aware storage is enabled by default. */
abstract Tls<T>(hl.Abstract<"haxeon_tls">) {
	public inline function get():T
		return cast TlsNative.native_tls_get(cast this);

	public inline function set(value:T):Void
		TlsNative.native_tls_set(cast this, cast value);

	public inline function clear():Void
		TlsNative.native_tls_clear(cast this);

	public inline function close():Void
		TlsNative.native_tls_close(cast this);
}
