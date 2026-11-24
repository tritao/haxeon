package haxeon.rpc;

/** Wire representation of an RPC error. */
@:wire typedef RpcErrorData = {
	@:id(1) var code:String;
	@:id(2) var message:String;
	@:id(3) var ambiguous:Bool;
}
