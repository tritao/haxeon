package haxeon.agent;

/** Receives one streamed completion. Exactly one of `complete` or `fail` ends the stream. */
interface ModelSink {
	function text(delta:String):Void;
	function toolUse(call:ToolCall):Void;
	function complete(reason:StopReason):Void;
	function fail(message:String):Void;
}
