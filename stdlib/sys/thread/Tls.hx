package sys.thread;

#if wasm
/** Thread-local storage on a single-threaded target: one value for each stand-in thread (see ThreadState), unset until that thread sets it. */
class Tls<T> {
	/** The value the current thread set, or null before it sets one. */
	public var value(get, set):T;

	final threads:Array<Int> = [];
	final values:Array<Null<T>> = [];

	/** Storage no thread has set yet. */
	public function new() {}

	function get_value():T {
		var index = threads.indexOf(ThreadState.current);
		return index < 0 ? null : values[index];
	}

	function set_value(value:T):T {
		var index = threads.indexOf(ThreadState.current);
		// Stand-in thread identities are never reused. Drop an explicitly cleared worker slot so
		// repeated short-lived threads do not retain an unbounded list of empty entries.
		if (value == null && ThreadState.current != 0) {
			if (index >= 0) {
				var last = threads.length - 1;
				if (index != last) {
					threads[index] = threads[last];
					values[index] = values[last];
				}
				threads.resize(last);
				values.resize(last);
			}
			return value;
		}
		if (index < 0) {
			threads.push(ThreadState.current);
			values.push(value);
		} else
			values[index] = value;
		return value;
	}
}
#else
/** Thread-local storage (`std.thread.ThreadLocal`): each thread sees its own `value`, null until that thread sets it. */
class Tls<T> {
	/** The value the current thread set, or null before it sets one. */
	public var value(get, set):T;

	final local = new std.thread.ThreadLocal<T>();

	/** Storage no thread has set yet. */
	public function new() {}

	function get_value():T
		return local.value;

	function set_value(value:T):T {
		local.value = value;
		return value;
	}
}
#end
