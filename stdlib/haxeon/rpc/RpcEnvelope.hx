package haxeon.rpc;

import haxe.io.Bytes;

/** Permanent variant ids. Request ids belong only to one connection generation. */
@:wire enum RpcEnvelope {
	@:id(1) Hello(protocol:Int, codec:Int, application:String, capabilities:Array<String>);
	@:id(2) Welcome(protocol:Int, codec:Int, application:String, capabilities:Array<String>);
	@:id(3) Refused(error:RpcError);
	@:id(4) Request(id:Int, method:Int, timeoutMs:Int, payload:Bytes);
	@:id(5) Response(id:Int, payload:Bytes);
	@:id(6) Failed(id:Int, error:RpcError);
	@:id(7) Cancel(id:Int);
	@:id(8) Notification(method:Int, payload:Bytes);
}
