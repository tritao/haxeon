package haxeon.agent;

import haxe.io.Bytes;

interface HttpStreamSink {
	function headers(status:Int):Void;
	function chunk(bytes:Bytes):Void;
	/** Ends the stream normally. Transport failures call `fail` instead. */
	function complete():Void;
	function fail(message:String):Void;
}
