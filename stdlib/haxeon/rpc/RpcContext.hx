package haxeon.rpc;

import haxe.io.Bytes;

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

	public function fail(error:RpcError):Bool {
		if (!state.isActive())
			return false;
		return complete(Bytes.alloc(0), error);
	}
}
