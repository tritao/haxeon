package haxeon.rpc;

import haxe.io.Bytes;
import haxeon.async.Future;

/** Completion is at most once; cancellation and expiry never promise rollback. */
class RpcContext<Response> {
	final state:RpcRequestState;
	final encode:Response->Bytes;
	final complete:(Bytes, Null<RpcError>) -> Bool;

	public function new(state:RpcRequestState, encode:Response->Bytes, complete:(Bytes, Null<RpcError>) -> Bool) {
		this.state = state;
		this.encode = encode;
		this.complete = complete;
	}

	public function deadline():Float
		return state.deadline;

	public function isCancelled():Bool
		return state.isCancelled();

	public function respond(value:Response):Bool {
		if (!state.isActive())
			return false;
		return complete(encode(value), null);
	}

	function respondFuture(future:Future<Response>):Void {
		@:privateAccess state.onCancel = () -> future.cancel();
		future.onComplete(function(outcome) {
			if (!state.isActive())
				return;
			try {
				switch outcome {
					case Success(value): respond(value);
					case Failure(error):
						if (Std.isOfType(error, RpcError))
							fail(cast error);
						else
							fail(new RpcError("handler_failed", "handler_failed", true));
					case Cancelled: fail(new RpcError("cancelled", "cancelled", true));
					case Stopped: fail(new RpcError("stopped", "stopped", true));
				}
			} catch (error:Dynamic) {
				if (!state.isActive())
					throw error;
				fail(new RpcError("handler_failed", "handler_failed", true));
			}
		});
	}

	public function fail(error:RpcError):Bool {
		if (!state.isActive())
			return false;
		return complete(Bytes.alloc(0), error);
	}
}
