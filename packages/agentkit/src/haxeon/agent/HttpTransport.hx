package haxeon.agent;

/**
	Streaming POST. Hosts supply this: NativeKit on desktop, `fetch` on the web.
	Sinks are called on the host's thread, never re-entrantly from `postStream`.
**/
interface HttpTransport {
	function postStream(request:HttpStreamRequest, sink:HttpStreamSink):Cancelable;
}
