package haxeon.platform.async;

import haxeon.platform.BindingError;
import haxeon.platform.async.Outcome;
import haxeon.platform.async.Promise;
import haxeon.platform.async.Requests;

/** A one-shot managed completion with explicit native cancellation and observation lifetime. */
class Future<T> {
	var outcome:Null<Outcome<T>>;
	var cancellation:Null<Void->Void>;
	var detach:Null<Void->Void>;
	var cancellationRequested:Bool = false;
	final callbacks:Array<Outcome<T>->Void> = [];

	@:allow(Promise)
	private function new() {}

	public function onComplete(callback:Outcome<T>->Void):Future<T> {
		if (callback == null) throw BindingError.invalidArgument("Future.onComplete", "Callback cannot be null");
		if (outcome != null) callback(outcome);
		else callbacks.push(callback);
		return this;
	}

	public function isComplete():Bool return outcome != null;
	public function canCancel():Bool return outcome == null && cancellation != null && !cancellationRequested;
	public function isCancellationRequested():Bool return cancellationRequested;

	/** Requests native cancellation and awaits a terminal event. False means no request was made. */
	public function cancel():Bool {
		var action = cancellation;
		if (outcome != null || cancellationRequested || action == null) return false;
		cancellationRequested = true;
		try action() catch (error:Dynamic) {
			cancellationRequested = false;
			throw error;
		}
		return true;
	}

	/** Detaches tracking and settles as Stopped without cancelling native work. */
	public function stopObserving():Bool {
		if (outcome != null) return false;
		if (detach != null) detach();
		finish(Stopped);
		return true;
	}

	@:allow(Requests)
	function setControls(cancel:Null<Void->Void>, detach:Void->Void):Void {
		this.cancellation = cancel;
		this.detach = detach;
	}

	@:allow(Promise)
	function finish(value:Outcome<T>):Void {
		if (outcome != null) return;
		outcome = value;
		cancellation = null;
		detach = null;
		var pending = callbacks.copy();
		callbacks.resize(0);
		var failure:Dynamic = null;
		for (callback in pending) {
			try callback(value) catch (error:Dynamic) {
				if (failure == null) failure = error;
			}
		}
		if (failure != null) throw failure;
	}
}
