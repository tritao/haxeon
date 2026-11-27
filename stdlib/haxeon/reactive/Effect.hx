package haxeon.reactive;

/** A side effect that reruns once after a source it read actually changes. */
class Effect extends ReactiveDependencySet {
	final action:Void->Void;
	var hasRun:Bool = false;

	/** Whether the effect is queued to run at the next `ReactiveRuntime.flushEffects`. */
	public var pending:Bool = false;

	/** Whether `dispose` was called: the effect never runs again. */
	public var disposed(default, null):Bool = false;

	/** An effect running `action` now, and again, once per flush, after a source `action` read changes. */
	public function new(action:Void->Void) {
		super();
		if (action == null)
			throw "Effect requires an action";
		this.action = action;
		run();
	}

	/** Runs the action when it has not run or a source it read changed, tracking what it reads. */
	@:allow(haxeon.reactive.ReactiveRuntime)
	public function run():Void {
		if (disposed || hasRun && !dirty) return;
		runBody();
	}

	/** Replaces subscriptions after a tracked callback's owner changes its input identity. */
	public function retrack():Void {
		if (!disposed) runBody();
	}

	function runBody():Void {
		beginDependencies();
		try {
			ReactiveRuntime.withTracking(this, action);
			finishDependencies();
			hasRun = true;
		} catch (error:Dynamic) {
			failDependencies();
			throw error;
		}
	}

	override public function onMaybeStale():Void
		ReactiveRuntime.enqueue(this);

	/** Stops the effect: it never runs again and drops its dependencies. */
	public function dispose():Void {
		disposed = true;
		pending = false;
		clearDependencies();
	}
}
