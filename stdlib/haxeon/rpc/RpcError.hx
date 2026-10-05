package haxeon.rpc;

/** Stable machine-readable code plus user-facing detail; never a remote exception. */
@:wire typedef RpcError = {
	@:id(1) var code:String;
	@:id(2) var message:String;
	@:id(3) var ambiguous:Bool;
}
