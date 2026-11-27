package haxeon.rpc;

import haxe.io.Bytes;

internal typedef RpcRoute = {
	final selectors:Array<RpcMethodKey>;
	final handle:(Bytes, RpcRequestState) -> Void;
}

/**
 * An RPC method: its permanent identity, by number, by qualified name or both, and the codecs of its request and response.
 * Both peers declare the same method; nothing is dispatched by reflection.
 */
class RpcMethod<Request, Response> {
	/** The method's number: positive, or 0 for a method routed by name only. */
	public final id:Int;

	/** How a request names the method. */
	public final key:RpcMethodKey;

	/** The method's qualified name, `Service.method`, or null for one with only a number. */
	public final name:Null<String>;

	/** Encodes a request. */
	public final encodeRequest:Request->Bytes;

	/** Decodes a request; throws for bytes that are not one. */
	public final decodeRequest:Bytes->Request;

	/** Encodes a response. */
	public final encodeResponse:Response->Bytes;

	/** Decodes a response; throws for bytes that are not one. */
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
				finish(state, Bytes.alloc(0), new RpcError(code, code, false));
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
