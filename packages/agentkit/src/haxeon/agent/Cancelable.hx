package haxeon.agent;

/** A running request the host can abandon. Cancelling twice or after completion is harmless. */
interface Cancelable {
	function cancel():Void;
}
