package haxeon.async;

/** Completion owner for one Future. */
class Promise<T> {
	public final future:Future<T>;

	public function new() future = new Future<T>();

	/** Installs the producer's cancellation and observation hooks before publishing the future. */
	public function setControls(cancel:Null<Void->Void>, ?detach:Void->Void):Void {
		if (!future.isComplete()) future.setControls(cancel, detach);
	}

	public function resolve(outcome:Outcome<T>):Void {
		if (outcome == null) throw new haxe.Exception("Promise outcome cannot be null");
		switch outcome {
			case Failure(error): fail(error);
			default: future.finish(outcome);
		}
	}

	public function complete(value:T):Void future.finish(Success(value));
	public function fail(error:haxe.Exception):Void {
		if (error == null) throw new haxe.Exception("Promise error cannot be null");
		future.finish(Failure(error));
	}
	public function cancel():Void future.finish(Cancelled);
}
