package haxeon.agent;

class HttpStreamRequest {
	public final url:String;
	public final headers:Array<HttpHeaderField>;
	public final body:String;

	public function new(url:String, headers:Array<HttpHeaderField>, body:String) {
		this.url = url;
		this.headers = headers;
		this.body = body;
	}
}
