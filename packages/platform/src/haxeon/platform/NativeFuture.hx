package haxeon.platform;

import haxeon.platform.NativeKitRequestOutcome;

/** A one-shot result completed by a NativeKit event. */
class NativeFuture<T> {
	var outcome:Null<NativeKitRequestOutcome<T>>;
	var cancellation:Null<Void->Void>;
	var cancellationRequested:Bool = false;
	final callbacks:Array<NativeKitRequestOutcome<T>->Void> = [];

	@:allow(NativePromise)
	private function new() {}

	public function onComplete(callback:NativeKitRequestOutcome<T>->Void):NativeFuture<T> {
		if (callback == null) throw "NativeFuture callback cannot be null";
		if (outcome != null) callback(outcome);
		else callbacks.push(callback);
		return this;
	}

	public function isComplete():Bool return outcome != null;

	/** Requests cancellation. Native dialogs/tasks settle on acknowledgement; other requests stop observation. */
	public function cancel():Void {
		if (outcome != null || cancellationRequested) return;
		if (cancellation != null) {
			cancellation();
			cancellationRequested = true;
		} else finish(Cancelled);
	}

	@:allow(NativeKitRequests)
	function setCancellation(action:Void->Void):Void cancellation = action;

	@:allow(NativePromise)
	@:allow(NativeKitRequests)
	function finish(value:NativeKitRequestOutcome<T>):Void {
		if (outcome != null) return;
		outcome = value;
		cancellation = null;
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
