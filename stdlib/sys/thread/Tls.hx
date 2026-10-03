package sys.thread;

#if wasm
/** Thread-local storage on a single-threaded target: one value for each stand-in thread (see ThreadState), unset until that thread sets it. */
class Tls<T> {
	public var value(get, set):T;

	final threads:Array<Int> = [];
	final values:Array<Null<T>> = [];

	public function new() {}

	function get_value():T {
		var index = threads.indexOf(ThreadState.current);
		return index < 0 ? null : values[index];
	}

	function set_value(value:T):T {
		var index = threads.indexOf(ThreadState.current);
		if (index < 0) {
			threads.push(ThreadState.current);
			values.push(value);
		} else
			values[index] = value;
		return value;
	}
}
#else
/**
 * Thread-local storage backed by HashLink's: each thread sees its own `value`, null until that
 * thread sets it. The value is a GC root while the thread holds it.
 */
class Tls<T> {
	public var value(get, set):T;

	final handle:hl.Abstract<"hl_tls">;

	public function new()
		handle = nativeTlsAlloc(true);

	function get_value():T
		return nativeTlsGet(handle);

	function set_value(value:T):T {
		nativeTlsSet(handle, value);
		return value;
	}
}

@:hlNative("std", "tls_alloc")
extern function nativeTlsAlloc(gcValue:Bool):hl.Abstract<"hl_tls">;
@:hlNative("std", "tls_get")
extern function nativeTlsGet(tls:hl.Abstract<"hl_tls">):Dynamic;
@:hlNative("std", "tls_set")
extern function nativeTlsSet(tls:hl.Abstract<"hl_tls">, value:Dynamic):Void;
#end
