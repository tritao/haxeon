package haxeon.reactive;

/** Lazily recomputed value whose version changes only when its output changes. */
class Derived<T> extends ReactiveDependencySet {
	final compute:Void->T;
	var current:T;
	var initialized:Bool = false;
	var computing:Bool = false;

	/** A value `compute` gives, computed on its first read and again on a read after something it read changed. */
	public function new(compute:Void->T) {
		super();
		if (compute == null)
			throw "Derived requires a computation";
		this.compute = compute;
	}

	/**
	 * The current value, computed first when it is not current. Reading it inside a tracked computation makes that
	 * computation depend on it. Throws what `compute` throws, and for a computation that reads its own value.
	 */
	public var value(get, never):T;
	function get_value():T {
		if (computing) throw new DerivedCycleError();
		try {
			ensureCurrent();
		} catch (error:Dynamic) {
			// Other failures still subscribe the reader so it can recover when an input changes.
			// A cycle must never add the edge that would make the dependency graph cyclic.
			if (!Std.isOfType(error, DerivedCycleError)) recordRead();
			throw error;
		}
		recordRead();
		return current;
	}

	override public function ensureCurrent():Void {
		if (computing) throw new DerivedCycleError();
		if (initialized && !isDirtyState() && !hasMaybeStaleInputs()) return;
		if (initialized && !isDirtyState() && !sourcesChanged()) {
			markClean();
			return;
		}
		var hadValue = initialized;
		beginDependencies();
		computing = true;
		try {
			var next = ReactiveRuntime.withTracking(this, compute);
			finishDependencies();
			var changed = !initialized || !haxeon.Equality.equals(current, next);
			current = next;
			initialized = true;
			if (hadValue && changed) publishVersionChange();
			computing = false;
		} catch (error:Dynamic) {
			computing = false;
			// Keep old links until a successful pull; partially discovered links are pruned on the next run.
			markFailed();
			throw error;
		}
	}

	/** Drops the value's dependencies, so changes to them no longer reach it. */
	public function dispose():Void
		clearDependencies();
}

/** A distinct failure lets readers avoid subscribing only to cyclic pulls. */
private class DerivedCycleError {
	public function new() {}
	public function toString():String return "Cyclic Derived computation";
}
