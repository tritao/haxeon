package haxeon.platform.interop;

import haxe.Int64;

class TransportSendQueue {
	public final queuedBytes:Int64;
	public final capacity:Int64;

	public function new(queuedBytes:Int64, capacity:Int64) {
		this.queuedBytes = queuedBytes;
		this.capacity = capacity;
	}
}
