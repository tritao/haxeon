package haxeon.platform.http;

import haxeon.platform.http.HttpHeader;

/** Fully managed HTTP response snapshot, safe after its NativeKit event is released. */
class HttpResponse {
	/** The HTTP status code. */
	public final statusCode:Int;

	/** Whether it was redirected, came from a cache or has a body, as NativeKit's response flags. */
	public final flags:Int;

	/** The body's declared length, in bytes. */
	public final contentLength:haxe.Int64;

	/** Its headers. */
	public final headers:Array<HttpHeader>;

	/** The body bytes the event delivered. */
	public final body:haxe.io.Bytes;

	/** A response with `statusCode`. */
	public function new(statusCode:Int, flags:Int, contentLength:haxe.Int64,
			headers:Array<HttpHeader>, body:haxe.io.Bytes) {
		this.statusCode = statusCode;
		this.flags = flags;
		this.contentLength = contentLength;
		this.headers = headers;
		this.body = body;
	}
}
