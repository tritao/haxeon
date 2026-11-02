package haxeon.reactive;

/** Mutable reactive value. Reads track; equal writes do not invalidate readers. */
class Signal<T> extends ReactiveSource {
	var current:T;

	public function new(value:T) {
		super();
		current = value;
	}

	public var value(get, set):T;
	inline function get_value():T {
		recordRead();
		return current;
	}

	function set_value(value:T):T {
		ReactiveRuntime.assertSignalWritable(this);
		if (haxeon.Equality.equals(current, value))
			return current;
		current = value;
		bumpVersion();
		invalidateReaders();
		return current;
	}

	public function update(value:T):T
		return this.value = value;
}
