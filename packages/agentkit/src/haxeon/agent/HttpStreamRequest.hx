package haxeon.agent;

/** An HTTP POST whose response is read as a stream. */
class HttpStreamRequest {
	/** Where it is posted. */
	public final url:String;

	/** Its headers. */
	public final headers:Array<HttpHeaderField>;

	/** Its body. */
	public final body:String;

	/** A POST of `body` to `url`. */
	public function new(url:String, headers:Array<HttpHeaderField>, body:String) {
		this.url = url;
		this.headers = headers;
		this.body = body;
	}
}
