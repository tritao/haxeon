package haxeon.agent.nativekit;

import haxe.io.Bytes;
import haxeon.agent.Cancelable;
import haxeon.agent.HttpStreamRequest;
import haxeon.agent.HttpStreamSink;
import haxeon.agent.HttpTransport;
import haxeon.platform.NativeKitException;
import haxeon.platform.event.EventPump;
import haxeon.platform.http.HttpClient;
import haxeon.platform.http.HttpRequest;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;

/**
	Streaming POST over the platform's HTTP client. Progress is driven by the host's
	shared NativeKit event pump: nothing here blocks, polls or owns a thread.
**/
class NativeKitHttpTransport implements HttpTransport {
	final client:HttpClient;

	/**
		`allowHttp` admits plain HTTP so tests and local gateways can run without TLS. Throws a
		`NativeKitException` where the platform has no HTTP client.
	**/
	public function new(events:EventPump, allowHttp:Bool = false) {
		client = switch HttpClient.create(events, allowHttp) {
			case Ok(created): created;
			case Err(error): throw new NativeKitException(error, "NativeKitHttpTransport.new", 0);
		};
	}

	/** Posts `request` and streams the response to `sink`; the result cancels the request. */
	public function postStream(request:HttpStreamRequest, sink:HttpStreamSink):Cancelable {
		if (client.isDisposed()) {
			sink.fail("The HTTP transport is closed");
			return new NativeKitStreamRequest(null, sink);
		}
		var outgoing = new HttpRequest(HttpMethod.Post, request.url);
		for (field in request.headers)
			outgoing.header(field.name, field.value);
		outgoing.body = Bytes.ofString(request.body);
		outgoing.streaming = true;
		try {
			return new NativeKitStreamRequest(client.send(outgoing), sink);
		} catch (error:Dynamic) {
			sink.fail("Could not start the HTTP request: " + Std.string(error));
			return new NativeKitStreamRequest(null, sink);
		}
	}

	/** Cancels the open requests and closes the client. */
	public function dispose():Void
		client.dispose();
}
