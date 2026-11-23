package haxeon.rpc;

import haxe.io.Bytes;

typedef RpcRoute = {
	final selectors:Array<RpcMethodKey>;
	final handle:(Bytes, RpcRequestState) -> Void;
}

/** Permanent method identity and concrete typed codecs. No reflection dispatch. */
class RpcMethod<Request, Response> {
	public final id:Int;
	public final key:RpcMethodKey;
	public final name:Null<String>;
	public final encodeRequest:Request->Bytes;
	public final decodeRequest:Bytes->Request;
	public final encodeResponse:Response->Bytes;
	public final decodeResponse:Bytes->Response;

	/** A qualified service method uses zero for name routing or a positive ID scoped to its interface. */
	public function new(id:Int, encodeRequest:Request->Bytes, decodeRequest:Bytes->Request,
			encodeResponse:Response->Bytes, decodeResponse:Bytes->Response, ?name:String) {
		if (name == null) {
			if (id <= 0)
				throw "RPC method id must be positive";
			key = Id(id);
		} else {
			var separator = name.lastIndexOf(".");
			if (id < 0 || separator <= 0 || separator == name.length - 1)
				throw "Invalid RPC service method";
			key = id == 0 ? Name(name) : ServiceId(name.substring(0, separator), id);
		}
		this.name = name;
		this.id = id;
		this.encodeRequest = encodeRequest;
		this.decodeRequest = decodeRequest;
		this.encodeResponse = encodeResponse;
		this.decodeResponse = decodeResponse;
	}

	function route(handler:(Request, RpcContext<Response>) -> Void,
			finish:(RpcRequestState, Bytes, Null<RpcError>) -> Bool):RpcRoute {
		var selectors = [key];
		if (id > 0 && name != null)
			selectors.push(Name(name));
		var handle = function(payload:Bytes, state:RpcRequestState) {
			var request:Request;
			try
				request = decodeRequest(payload)
			catch (_:Dynamic) {
				var code = "invalid_request";
				finish(state, Bytes.alloc(0), {code: code, message: code, ambiguous: false});
				return;
			}
			var context = new RpcContext(state, encodeResponse,
				function(bytes, error) return finish(state, bytes, error));
			handler(request, context);
		};
		return {selectors: selectors, handle: handle};
	}

	/**
		Creates a method with a positive numeric ID. Haxeon generates MessagePack codecs for the request
		and response types of the expected RpcMethod.
	 */
	public static function wire<Req, Res>(id:Int):RpcMethod<Req, Res>
		throw new haxe.Exception("RpcMethod.wire must be lowered by the compiler");
}
