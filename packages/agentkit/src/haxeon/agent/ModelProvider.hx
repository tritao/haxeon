package haxeon.agent;

/** A model backend. Implementations own transport, authentication and wire format. */
interface ModelProvider {
	/** Asks for one model turn, streamed to `sink`; the result cancels it. */
	function start(request:ModelRequest, sink:ModelSink):Cancelable;
}
