package haxeon.platform;

/** Fully managed HTTP response snapshot, safe after its NativeKit event is released. */
class NativeKitHttpResponse {
	public final statusCode:Int;
	public final flags:Int;
	public final contentLength:haxe.Int64;
	public final headers:Array<NativeKitHttpHeader>;
	public final body:haxe.io.Bytes;

	public function new(statusCode:Int, flags:Int, contentLength:haxe.Int64,
		headers:Array<NativeKitHttpHeader>, body:haxe.io.Bytes) {
		this.statusCode = statusCode;
		this.flags = flags;
		this.contentLength = contentLength;
		this.headers = headers;
		this.body = body;
	}
}

/** One copied HTTP response header. Duplicate headers remain separate entries. */
class NativeKitHttpHeader {
	public final name:String;
	public final value:String;

	public function new(name:String, value:String) {
		this.name = name;
		this.value = value;
	}
}
