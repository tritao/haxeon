package haxeon.rpc;

import haxe.io.Bytes;

/** Permanent method identity and concrete typed codecs. No reflection dispatch. */
class RpcMethod<Request, Response> {
	public final id:Int;
	public final encodeRequest:Request->Bytes;
	public final decodeRequest:Bytes->Request;
	public final encodeResponse:Response->Bytes;
	public final decodeResponse:Bytes->Response;

	public function new(id:Int, encodeRequest:Request->Bytes, decodeRequest:Bytes->Request, encodeResponse:Response->Bytes, decodeResponse:Bytes->Response) {
		if (id <= 0)
			throw "RPC method id must be positive";
		this.id = id;
		this.encodeRequest = encodeRequest;
		this.decodeRequest = decodeRequest;
		this.encodeResponse = encodeResponse;
		this.decodeResponse = decodeResponse;
	}
}
