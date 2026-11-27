package haxeon.async;

/**
 * One-shot completion owned by a single thread. There is no background scheduler.
 * Producers deliver completion on the owner's poll or tick and must post there
 * first if work finishes elsewhere. Callbacks run on the owner, immediately if
 * already settled.
 */
class Future<T> {
	var outcome:Null<Outcome<T>>;
	var cancellation:Null<Void->Void>;
	var detach:Null<Void->Void>;
	var cancellationRequested:Bool = false;
	final callbacks:Array<Outcome<T>->Void> = [];

	@:allow(haxeon.async.Promise)
	private function new() {}

	/** Calls `callback` with the outcome once the future settles, or now when it has. Returns the future, to chain. */
	public function onComplete(callback:Outcome<T>->Void):Future<T> {
		if (callback == null) throw new haxe.Exception("Future callback cannot be null");
		if (outcome != null) callback(outcome);
		else callbacks.push(callback);
		return this;
	}

	/** Whether the future has settled: succeeded, been cancelled or stopped. */
	public function isComplete():Bool return outcome != null;

	/**
	 * Whether `cancel` would make a request: the future is pending, its producer can cancel it, and none was made yet.
	 */
	public function canCancel():Bool return outcome == null && cancellation != null && !cancellationRequested;

	/** Whether `cancel` made a request the producer has not yet settled the future for. */
	public function isCancellationRequested():Bool return cancellationRequested;

	/** Requests cancellation; the producer settles the future. False means no request was made. */
	public function cancel():Bool {
		var action = cancellation;
		if (outcome != null || cancellationRequested || action == null) return false;
		cancellationRequested = true;
		try action() catch (error:Dynamic) {
			if (outcome == null) cancellationRequested = false;
			throw error;
		}
		return true;
	}

	/** Detaches tracking and settles as Stopped without cancelling the work. */
	public function stopObserving():Bool {
		if (outcome != null) return false;
		finish(Stopped, detach);
		return true;
	}

	@:allow(haxeon.async.Promise)
	function setControls(cancel:Null<Void->Void>, detach:Null<Void->Void>):Void {
		this.cancellation = cancel;
		this.detach = detach;
	}

	@:allow(haxeon.async.Promise)
	function finish(value:Outcome<T>, ?beforeCallbacks:Void->Void):Void {
		if (outcome != null) return;
		outcome = value;
		cancellation = null;
		detach = null;
		var pending = callbacks.copy();
		callbacks.resize(0);
		var failure:Dynamic = null;
		if (beforeCallbacks != null)
			try beforeCallbacks() catch (error:Dynamic) failure = error;
		for (callback in pending) {
			try callback(value) catch (error:Dynamic) {
				if (failure == null) failure = error;
			}
		}
		if (failure != null) throw failure;
	}
}
