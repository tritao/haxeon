package haxeon.rpc;

/** RPC failure with a stable code and whether the request may have executed. */
class RpcError extends haxe.Exception {
	/** What failed, as a stable code to compare, such as `"disconnected"` or `"handler_failed"`. */
	public final code:String;

	/** Whether the request may have run on the peer although it failed here, so retrying it may run it twice. */
	public final ambiguous:Bool;

	/** An error with `code`, `message`, and whether the request may have run. */
	public function new(code:String, message:String, ambiguous:Bool) {
		super(message);
		this.code = code;
		this.ambiguous = ambiguous;
	}

	function toWire():RpcErrorData
		return {code: code, message: message, ambiguous: ambiguous};

	static function fromWire(data:RpcErrorData):RpcError
		return new RpcError(data.code, data.message, data.ambiguous);
}
