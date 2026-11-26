package haxeon.platform.interop;

import haxe.Int64;

/** How full a transport's send queue is. */
class TransportSendQueue {
	/** The bytes waiting to be sent. */
	public final queuedBytes:Int64;

	/** The most the queue holds. */
	public final capacity:Int64;

	/** A queue holding `queuedBytes` of `capacity`. */
	public function new(queuedBytes:Int64, capacity:Int64) {
		this.queuedBytes = queuedBytes;
		this.capacity = capacity;
	}
}
