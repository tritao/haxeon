package haxeon.platform;

import haxeon.platform.NativeKitRequestOutcome;

/** Completion owner for one NativeFuture. */
class NativePromise<T> {
	public final future:NativeFuture<T>;

	public function new() future = new NativeFuture<T>();

	@:allow(NativeKitRequests)
	private function resolve(outcome:NativeKitRequestOutcome<T>):Void future.finish(outcome);

	public function complete(value:T):Void future.finish(Success(value));
	public function fail(error:NativeError):Void {
		if (error == null) throw BindingError.invalidArgument("NativePromise.fail", "Error cannot be null");
		future.finish(Failure(error));
	}
	public function cancel():Void future.finish(Cancelled);
}
