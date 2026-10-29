package haxeon.agent;

/** A model backend. Implementations own transport, authentication and wire format. */
interface ModelProvider {
	function start(request:ModelRequest, sink:ModelSink):Cancelable;
}
