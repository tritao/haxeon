package haxeon.agent;

import haxe.io.Bytes;

/** Receives a streamed HTTP response. */
interface HttpStreamSink {
	/** The response's status arrived. */
	function headers(status:Int):Void;

	/** More of the body arrived. */
	function chunk(bytes:Bytes):Void;
	/** Ends the stream normally. Transport failures call `fail` instead. */
	function complete():Void;

	/** The request failed; nothing follows. */
	function fail(message:String):Void;
}
