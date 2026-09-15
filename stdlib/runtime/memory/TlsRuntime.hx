package runtime.memory;

import runtime.memory.TlsNative;

/** Non-generic constructor boundary for typed TLS keys. */
class TlsRuntime {
	public static inline function create(?gcValue:Bool = true):Tls<Dynamic>
		return cast TlsNative.native_tls_alloc(gcValue);
}
