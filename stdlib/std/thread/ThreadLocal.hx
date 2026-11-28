package std.thread;

#if wasm
#error "std.thread is not available on Wasm: a Wasm module runs on one thread"
#end

/** A value each thread has its own of: null for a thread until it sets one. A thread's value is kept alive while it holds it. */
class ThreadLocal<T> {
	/** The calling thread's value, or null before it sets one. */
	public var value(get, set):Null<T>;

	final handle:hl.Abstract<"hl_tls">;

	/** A value no thread has set yet. */
	public function new()
		handle = nativeTlsAlloc(true);

	function get_value():Null<T>
		return nativeTlsGet(handle);

	function set_value(value:Null<T>):Null<T> {
		nativeTlsSet(handle, value);
		return value;
	}
}

@:hlNative("std", "tls_alloc")
internal extern function nativeTlsAlloc(gcValue:Bool):hl.Abstract<"hl_tls">;

@:hlNative("std", "tls_get")
internal extern function nativeTlsGet(tls:hl.Abstract<"hl_tls">):Dynamic;

@:hlNative("std", "tls_set")
internal extern function nativeTlsSet(tls:hl.Abstract<"hl_tls">, value:Dynamic):Void;
