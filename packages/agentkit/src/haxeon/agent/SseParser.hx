package haxeon.agent;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/** Incremental Server-Sent Events decoder. Chunks may split lines, multi-byte characters and events. */
class SseParser {
	final onEvent:(name:String, data:String) -> Void;
	var pending:BytesBuffer = new BytesBuffer();
	var pendingLength = 0;
	var eventName = "";
	var dataLines:Array<String> = [];
	var started = false;

	public function new(onEvent:(name:String, data:String) -> Void)
		this.onEvent = onEvent;

	public function feed(chunk:Bytes):Void {
		for (index in 0...chunk.length) {
			var byte = chunk.get(index);
			if (byte == 10) {
				line(takeLine());
			} else {
				pending.addByte(byte);
				pendingLength++;
			}
		}
	}

	/** Flushes a final event the server did not terminate with a blank line. */
	public function finish():Void {
		if (pendingLength > 0)
			line(takeLine());
		dispatch();
	}

	function takeLine():String {
		var bytes = pending.getBytes();
		pending = new BytesBuffer();
		pendingLength = 0;
		var text = bytes.toString();
		return StringTools.endsWith(text, "\r") ? text.substr(0, text.length - 1) : text;
	}

	function line(text:String):Void {
		if (text == "") {
			dispatch();
			return;
		}
		if (text.charAt(0) == ":")
			return;
		var colon = text.indexOf(":");
		var field = colon < 0 ? text : text.substr(0, colon);
		var value = colon < 0 ? "" : text.substr(colon + 1);
		if (value.charAt(0) == " ")
			value = value.substr(1);
		switch field {
			case "event":
				eventName = value;
				started = true;
			case "data":
				dataLines.push(value);
				started = true;
			default:
		}
	}

	function dispatch():Void {
		if (!started)
			return;
		var name = eventName == "" ? "message" : eventName;
		var data = dataLines.join("\n");
		eventName = "";
		dataLines = [];
		started = false;
		onEvent(name, data);
	}
}
