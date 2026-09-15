package runtime.memory;

/** HashLink-only implementation boundary for explicit TLS interop. */
@:hlNative("haxeon_runtime")
class TlsNative {
	public static function native_tls_alloc(gcValue:Bool):hl.Abstract<"haxeon_tls">
		return null;

	public static function native_tls_get(tls:hl.Abstract<"haxeon_tls">):Dynamic
		return null;

	public static function native_tls_set(tls:hl.Abstract<"haxeon_tls">, value:Dynamic):Void {}

	public static function native_tls_clear(tls:hl.Abstract<"haxeon_tls">):Void {}

	public static function native_tls_close(tls:hl.Abstract<"haxeon_tls">):Void {}
}
