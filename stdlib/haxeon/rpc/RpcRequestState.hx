package haxeon.rpc;

/** The life of one request a peer made: whether it is still wanted. Its handler may keep it after the connection closes. */
class RpcRequestState {
	/** The request's number on its connection. */
	public final id:Int;

	/** When the request expires, in the connection's clock milliseconds. */
	public final deadline:Float;

	/** Whether the request was cancelled: the peer withdrew it or the connection closed. */
	public var cancelled(default, null):Bool = false;

	/** Whether the request is over: answered, or cancelled. */
	public var finished(default, null):Bool = false;

	final clock:Void->Float;
	@:allow(haxeon.rpc.RpcContext) var onCancel:Null<Void->Void>;

	internal function new(id:Int, deadline:Float, clock:Void->Float) {
		this.id = id;
		this.deadline = deadline;
		this.clock = clock;
	}

	/** Whether the request was cancelled or has expired. */
	public function isCancelled():Bool
		return cancelled || clock() >= deadline;

	/** Whether the request is still wanted: not finished, cancelled or expired. */
	public function isActive():Bool
		return !finished && !isCancelled();

	internal function finish(cancelled:Bool):Void {
		this.finished = true;
		this.cancelled = cancelled;
		var notify = onCancel;
		onCancel = null;
		if (cancelled && notify != null)
			notify();
	}
}
