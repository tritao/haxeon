package haxeon.reactive;

/** Lazily recomputed value whose version changes only when its output changes. */
class Derived<T> extends ReactiveDependencySet {
	final compute:Void->T;
	var current:T;
	var initialized:Bool = false;

	public function new(compute:Void->T) {
		super();
		if (compute == null)
			throw "Derived requires a computation";
		this.compute = compute;
	}

	public var value(get, never):T;
	function get_value():T {
		ensureCurrent();
		recordRead();
		return current;
	}

	override public function ensureCurrent():Void {
		if (initialized && !isDirtyState() && !hasMaybeStaleInputs()) return;
		if (initialized && !isDirtyState() && !sourcesChanged()) {
			markClean();
			return;
		}
		var hadValue = initialized;
		beginDependencies();
		try {
			var next = ReactiveRuntime.withTracking(this, compute);
			finishDependencies();
			var changed = !initialized || !haxeon.Equality.equals(current, next);
			current = next;
			initialized = true;
			if (hadValue && changed) publishVersionChange();
		} catch (error:Dynamic) {
			// Keep old links until a successful pull; partially discovered links are pruned on the next run.
			markFailed();
			throw error;
		}
	}

	public function dispose():Void
		clearDependencies();
}
