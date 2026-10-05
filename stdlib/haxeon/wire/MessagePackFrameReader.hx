package haxeon.wire;

import haxe.io.Bytes;

/** Incremental HMPK assembly. feed returns bytes consumed; zero means backpressure.
 * A caller keeps the unconsumed input and drains take() before feeding again.
 * Memory is bounded by maxQueuedBytes plus the ten-byte header. */
class MessagePackFrameReader {
	final maxPayload:Int;
	final maxQueuedBytes:Int;
	final maxMessages:Int;
	final header:Bytes = Bytes.alloc(MessagePackFrame.HEADER_BYTES);
	final queued:Array<Bytes> = [];
	var headerUsed:Int = 0;
	var payload:Null<Bytes>;
	var payloadUsed:Int = 0;
	var reservedBytes:Int = 0;
	var failed:Bool = false;

	public function new(maxPayload:Int = 4 * 1024 * 1024, maxQueuedBytes:Int = 8 * 1024 * 1024, maxMessages:Int = 32) {
		if (maxPayload < 0
			|| maxQueuedBytes < maxPayload
			|| maxQueuedBytes > 0x7fffffff - MessagePackFrame.HEADER_BYTES
			|| maxMessages < 1)
			throw new MessagePackError("Invalid frame reader limits");
		this.maxPayload = maxPayload;
		this.maxQueuedBytes = maxQueuedBytes;
		this.maxMessages = maxMessages;
	}

	public function bufferedBytes():Int
		return reservedBytes + headerUsed;

	public function bufferedMessages():Int
		return queued.length;

	public function feed(bytes:Bytes, offset:Int, length:Int, budget:Int = 65536):Int {
		if (failed)
			throw new MessagePackError("Frame reader failed; start a fresh connection");
		if (bytes == null || offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset || budget < 0)
			throw new MessagePackError("Invalid frame input range");
		var limit = Std.int(Math.min(length, budget));
		var consumed = 0;
		while (consumed < limit) {
			if (queued.length >= maxMessages)
				break;
			if (headerUsed < header.length) {
				var count = Std.int(Math.min(header.length - headerUsed, limit - consumed));
				header.blit(headerUsed, bytes, offset + consumed, count);
				headerUsed += count;
				consumed += count;
				if (headerUsed < header.length)
					break;
			}
			if (payload == null) {
				var size:Int;
				try
					size = MessagePackFrame.payloadLength(header, maxPayload);
				catch (error:Dynamic) {
					failed = true;
					throw error;
				}
				if (size > maxQueuedBytes - reservedBytes)
					break;
				payload = Bytes.alloc(size);
				reservedBytes += size;
				payloadUsed = 0;
			}
			var count = Std.int(Math.min(payload.length - payloadUsed, limit - consumed));
			payload.blit(payloadUsed, bytes, offset + consumed, count);
			payloadUsed += count;
			consumed += count;
			if (payloadUsed == payload.length) {
				queued.push(payload);
				payload = null;
				headerUsed = 0;
			}
		}
		return consumed;
	}

	/** Transfers an assembled payload without a second framing copy. */
	public function take():Null<Bytes> {
		if (queued.length == 0)
			return null;
		var value = queued.shift();
		reservedBytes -= value.length;
		return value;
	}
}
