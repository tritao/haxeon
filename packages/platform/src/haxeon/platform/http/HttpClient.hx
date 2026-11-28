package haxeon.platform.http;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import haxeon.platform.event.EventPump;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetConstants;
import nativekit.ffi.NativeKitNetTypes.HttpClientOptions;
import nativekit.ffi.NativeKitNetTypes.OwnedHttpClientHandle;

/**
 * NativeKit's HTTP client. Each request it sends answers through its `HttpExchange`, which the event pump settles as
 * NativeKit reports; nothing blocks. Disposing it ends the exchanges in flight as cancelled.
 */
class HttpClient implements Disposable {
	final events:EventPump;
	final owned:OwnedHttpClientHandle;
	final exchanges:Array<HttpExchange> = [];
	var disposed = false;

	function new(events:EventPump, owned:OwnedHttpClientHandle) {
		this.events = events;
		this.owned = owned;
	}

	/**
	 * A client answering through `events`; `allowHttp` admits plain HTTP, as for a local server. `Unsupported` where
	 * the platform has no HTTP client.
	 */
	public static function create(events:EventPump, allowHttp:Bool = false):Result<HttpClient, NativeKitError> {
		if (events == null)
			throw BindingError.invalidArgument("HttpClient.create", "An HTTP client answers through an event pump");
		var options = new HttpClientOptions();
		if (allowHttp)
			options.set_flags(NativeKitNetConstants.NK_HTTP_CLIENT_ALLOW_HTTP);
		var created = NativeKitNet.nk_http_client_create(options);
		return NativeKitStatus.made(created.status, "HttpClient.create", NativeKit.nk_last_error(),
			() -> new HttpClient(events, created.out_client));
	}

	/** Sends `request`. Throws a `BindingError` for a request NativeKit refuses, such as one with no valid URL. */
	public function send(request:HttpRequest):HttpExchange {
		ensureLive();
		if (request == null || request.url == null || request.url.length == 0)
			throw BindingError.invalidArgument("HttpClient.send", "An HTTP request needs a URL");
		if (!Math.isFinite(request.timeoutSeconds) || request.timeoutSeconds < 0 || request.timeoutSeconds > 2147483)
			throw BindingError.invalidArgument("HttpClient.send",
				"An HTTP timeout is 0 or a positive number of seconds");
		var started = NativeKitNet.nk_http_request(owned.borrow(), request.nativeValue());
		NativeKitStatus.check(started.status, "HttpClient.send", NativeKit.nk_last_error());
		var exchange = new HttpExchange(started.out_request, request.streaming ? started.out_stream : null, forget);
		exchanges.push(exchange);
		events.trackExchange(exchange);
		return exchange;
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		for (exchange in exchanges.copy())
			exchange.abandon();
		owned.close();
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	function forget(exchange:HttpExchange):Void {
		exchanges.remove(exchange);
		events.forgetExchange(exchange);
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("HttpClient.send", "The HTTP client has been disposed");
	}
}
