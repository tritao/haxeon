package haxeon.platform.http;

import haxe.io.Bytes;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;
import nativekit.ffi.NativeKitNetTypes.HttpRequestMode;
import nativekit.ffi.NativeKitNetTypes.HttpRequestOptions;
import nativekit.ffi.NativeKitNetTypes.NativeHttpHeader;

/** An HTTP request to send with `HttpClient.send`. */
class HttpRequest {
	/** The method. */
	public final method:HttpMethod;

	/** The absolute URL. */
	public final url:String;

	/** The headers to send; a name may repeat. */
	public final headers:Array<HttpHeader> = [];

	/** The body, or null for none. */
	public var body:Null<Bytes> = null;

	/**
	 * Whether the response body arrives in pieces as it is received (`HttpExchange.onData`) rather than whole in the
	 * completed response.
	 */
	public var streaming:Bool = false;

	/** How long the whole request may take, in seconds; 0 leaves it to the platform. */
	public var timeoutSeconds:Float = 0;

	/** The largest response body to accept, in bytes; a larger one fails as `TooLarge`. 0 leaves it to the platform. */
	public var maxResponseBytes:Int = 0;

	/** A `method` request to `url`. */
	public function new(method:HttpMethod, url:String) {
		this.method = method;
		this.url = url;
	}

	/** Adds the header `name: value`, returning the request to chain. */
	public function header(name:String, value:String):HttpRequest {
		headers.push(new HttpHeader(name, value));
		return this;
	}

	internal function nativeValue():HttpRequestOptions {
		var options = new HttpRequestOptions();
		options.set_method(method);
		options.set_url(url);
		options.set_headers([for (field in headers) {
			var header = new NativeHttpHeader();
			header.set_name_bytes(Bytes.ofString(field.name));
			header.set_value_bytes(Bytes.ofString(field.value));
			header;
		}]);
		if (body != null)
			options.set_body_bytes(body);
		options.set_mode(streaming ? HttpRequestMode.Streaming : HttpRequestMode.Buffered);
		options.set_timeout_ms(Std.int(timeoutSeconds * 1000));
		if (maxResponseBytes > 0)
			options.set_max_response_size(haxe.Int64.ofInt(maxResponseBytes));
		return options;
	}
}
