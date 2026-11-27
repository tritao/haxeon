package haxeon.async;

/** The side of a `Future` that settles it: its producer keeps the promise and hands out `future`. */
class Promise<T> {
	/** The future this promise settles. */
	public final future:Future<T>;

	/** A promise with a pending future. */
	public function new() future = new Future<T>();

	/** Installs the producer's cancellation and observation hooks before publishing the future. */
	public function setControls(cancel:Null<Void->Void>, ?detach:Void->Void):Void {
		if (!future.isComplete()) future.setControls(cancel, detach);
	}

	/** Settles the future with `outcome`. Does nothing once it has settled. */
	public function resolve(outcome:Outcome<T>):Void {
		if (outcome == null) throw new haxe.Exception("Promise outcome cannot be null");
		switch outcome {
			case Failure(error): fail(error);
			default: future.finish(outcome);
		}
	}

	/** Settles the future with the value `value`. Does nothing once it has settled. */
	public function complete(value:T):Void future.finish(Success(value));

	/** Settles the future with the failure `error`. Does nothing once it has settled. */
	public function fail(error:haxe.Exception):Void {
		if (error == null) throw new haxe.Exception("Promise error cannot be null");
		future.finish(Failure(error));
	}

	/** Settles the future as cancelled. Does nothing once it has settled. */
	public function cancel():Void future.finish(Cancelled);
}
