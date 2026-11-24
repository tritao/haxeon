package haxeon.rpc;

/** RPC failure with a stable code and whether the request may have executed. */
class RpcError extends haxe.Exception {
	public final code:String;
	public final ambiguous:Bool;

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
