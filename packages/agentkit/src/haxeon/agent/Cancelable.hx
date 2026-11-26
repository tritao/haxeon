package haxeon.agent;

/** A running request the host can abandon. Cancelling twice or after completion is harmless. */
interface Cancelable {
	/** Stops the work; calling it again does nothing. */
	function cancel():Void;
}
