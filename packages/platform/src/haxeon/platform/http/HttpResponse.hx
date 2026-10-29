package haxeon.platform.http;

import haxeon.platform.http.HttpHeader;

/** Fully managed HTTP response snapshot, safe after its NativeKit event is released. */
class HttpResponse {
	public final statusCode:Int;
	public final flags:Int;
	public final contentLength:haxe.Int64;
	public final headers:Array<HttpHeader>;
	public final body:haxe.io.Bytes;

	public function new(statusCode:Int, flags:Int, contentLength:haxe.Int64,
		headers:Array<HttpHeader>, body:haxe.io.Bytes) {
		this.statusCode = statusCode;
		this.flags = flags;
		this.contentLength = contentLength;
		this.headers = headers;
		this.body = body;
	}
}
