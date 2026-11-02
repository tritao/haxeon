package haxeon.ui.core;

/** A side effect that reruns once after a source it read actually changes. */
class Effect extends ReactiveDependencySet {
	final action:Void->Void;
	var hasRun:Bool = false;
	public var pending:Bool = false;
	public var disposed(default, null):Bool = false;

	public function new(action:Void->Void) {
		super();
		if (action == null)
			throw "Effect requires an action";
		this.action = action;
		run();
	}

	@:allow(haxeon.ui.core.ReactiveRuntime)
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
			markFailed();
			throw error;
		}
	}

	override public function onMaybeStale():Void
		ReactiveRuntime.enqueue(this);

	public function dispose():Void {
		disposed = true;
		pending = false;
		clearDependencies();
	}
}
