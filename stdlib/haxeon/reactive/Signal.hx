package haxeon.reactive;

/** Mutable reactive value. Reads track; equal writes do not invalidate readers. */
class Signal<T> extends ReactiveSource {
	var current:T;

	/** A signal holding `value`. */
	public function new(value:T) {
		super();
		current = value;
	}

	/**
	 * The value. Reading it inside a tracked computation makes that computation depend on the signal; writing a value
	 * that differs (as `Equality.sameForChange` decides) invalidates what read it.
	 */
	public var value(get, set):T;
	inline function get_value():T {
		recordRead();
		return current;
	}

	function set_value(value:T):T {
		ReactiveRuntime.assertSignalWritable(this);
		var changed = !haxeon.Equality.sameForChange(current, value);
		current = value;
		if (changed) {
			bumpVersion();
			invalidateReaders();
		}
		return current;
	}

	/** Writes `value`, as assigning `value` does, and returns it. */
	public function update(value:T):T
		return this.value = value;
}
