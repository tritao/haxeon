package haxeon.platform.async;

import haxeon.platform.BindingError;
import haxeon.platform.PlatformError;
import haxeon.platform.async.Future;
import haxeon.platform.async.Outcome;
import haxeon.platform.async.Requests;

/** Completion owner for one Future. */
class Promise<T> {
	public final future:Future<T>;

	public function new() future = new Future<T>();

	@:allow(Requests)
	private function resolve(outcome:Outcome<T>):Void future.finish(outcome);

	public function complete(value:T):Void future.finish(Success(value));
	public function fail(error:PlatformError):Void {
		if (error == null) throw BindingError.invalidArgument("Promise.fail", "Error cannot be null");
		future.finish(Failure(error));
	}
	public function cancel():Void future.finish(Cancelled);
}
