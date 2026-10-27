package haxeon.agent.nativekit;

import haxe.io.Bytes;
import haxeon.agent.Cancelable;
import haxeon.agent.HttpStreamRequest;
import haxeon.agent.HttpStreamSink;
import haxeon.agent.HttpTransport;
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpClientOptions;
import nativekit.ffi.NativeKitNetTypes.HttpHeader;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;
import nativekit.ffi.NativeKitNetTypes.HttpRequestMode;
import nativekit.ffi.NativeKitNetTypes.HttpRequestOptions;
import nativekit.ffi.NativeKitNetTypes.OwnedHttpClientHandle;
import nativekit.ffi.NativeKitTypes.Result;

/**
	Streaming POST over NativeKit's HTTP client. Progress is driven by the host's
	shared NativeKit event pump: nothing here blocks, polls or owns a thread.
**/
class NativeKitHttpTransport implements HttpTransport {
	static inline var ReadChunk = 16384;

	final owner:OwnedHttpClientHandle;
	final subscription:NativeKitEventSubscription;
	final active:Map<String, NativeKitStreamRequest> = [];
	final scratch:Bytes = Bytes.alloc(ReadChunk);
	var disposed = false;

	/** `allowHttp` admits plain HTTP so tests and local gateways can run without TLS. */
	public function new(events:NativeKitEvents, allowHttp:Bool = false) {
		if (events == null)
			throw "Streaming HTTP transport requires the shared NativeKit event pump";
		var options = new HttpClientOptions();
		if (allowHttp)
			options.set_flags(1); // NK_HTTP_CLIENT_ALLOW_HTTP
		var created = NativeKitNet.nk_http_client_create(options);
		if (created.status != Result.Ok)
			throw "Could not create the NativeKit HTTP client";
		owner = created.out_client;
		subscription = events.listen(onEvent);
	}

	public function postStream(request:HttpStreamRequest, sink:HttpStreamSink):Cancelable {
		var handle = new NativeKitStreamRequest(this, sink);
		if (disposed) {
			handle.finishWith("The HTTP transport is closed");
			return handle;
		}
		try {
			var headers:Array<HttpHeader> = [];
			for (field in request.headers) {
				var header = new HttpHeader();
				header.set_name_bytes(Bytes.ofString(field.name));
				header.set_value_bytes(Bytes.ofString(field.value));
				headers.push(header);
			}
			var options = new HttpRequestOptions();
			options.set_method(HttpMethod.Post);
			options.set_url(request.url);
			options.set_headers(headers);
			options.set_body_bytes(Bytes.ofString(request.body));
			options.set_mode(HttpRequestMode.Streaming);
			options.set_timeout_ms(0);
			var started = NativeKitNet.nk_http_request(owner.borrow(), options);
			if (started.status != Result.Ok) {
				handle.finishWith("Could not start the HTTP request (" + started.status + ")");
				return handle;
			}
			handle.begin(started.out_request, started.out_stream);
			active.set(Std.string(started.out_request), handle);
		} catch (error:Dynamic) {
			handle.finishWith("Could not start the HTTP request: " + Std.string(error));
		}
		return handle;
	}

	@:allow(haxeon.agent.nativekit.NativeKitStreamRequest)
	function forget(handle:NativeKitStreamRequest):Void {
		for (key => value in active)
			if (value == handle) {
				active.remove(key);
				break;
			}
	}

	function onEvent(value:NativeKitEventValue):Void {
		switch value {
			case HttpHeaders(_, id, result, response):
				var handle = active.get(Std.string(id));
				if (handle != null)
					handle.headers(result, response.statusCode);
			case HttpDataAvailable(_, id):
				var handle = active.get(Std.string(id));
				if (handle != null)
					handle.drain(scratch);
			case HttpComplete(_, id, result, _):
				var handle = active.get(Std.string(id));
				if (handle != null)
					handle.complete(result, scratch);
			default:
		}
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		subscription.dispose();
		for (handle in [for (value in active) value])
			handle.cancel();
		owner.close();
	}
}
