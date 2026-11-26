package haxeon.agent;

/** Receives one streamed completion. Exactly one of `complete` or `fail` ends the stream. */
interface ModelSink {
	/** The model streamed more text. */
	function text(delta:String):Void;

	/** The model called a tool. */
	function toolUse(call:ToolCall):Void;

	/** The turn ended, for `reason`. */
	function complete(reason:StopReason):Void;

	/** The turn failed; nothing follows. */
	function fail(message:String):Void;
}
