package haxeon.rpc;

/** Shared lifetime token retained by asynchronous handlers after disconnect. */
class RpcRequestState {
	public final id:Int;
	public final deadline:Float;
	public var cancelled(default, null):Bool = false;
	public var finished(default, null):Bool = false;

	final clock:Void->Float;

	public function new(id:Int, deadline:Float, clock:Void->Float) {
		this.id = id;
		this.deadline = deadline;
		this.clock = clock;
	}

	public function isCancelled():Bool
		return cancelled || clock() >= deadline;

	public function isActive():Bool
		return !finished && !isCancelled();

	public function finish(cancelled:Bool):Void {
		this.finished = true;
		this.cancelled = cancelled;
	}
}
