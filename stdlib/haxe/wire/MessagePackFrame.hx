package haxe.wire;

import haxe.io.Bytes;

/**
	Minimal versioned frame for transporting one MessagePack value.

	Frame layout: four-byte "HMPK" magic, one-byte version, one-byte flags,
	then a four-byte big-endian payload length followed by the MessagePack
	payload. Version 1 currently reserves all flags and requires them to be 0.
 */
class MessagePackFrame {
	public static inline final CURRENT_VERSION:Int = 1;
	public static inline final HEADER_BYTES:Int = 10;

	static inline final MAGIC_0:Int = 0x48;
	static inline final MAGIC_1:Int = 0x4d;
	static inline final MAGIC_2:Int = 0x50;
	static inline final MAGIC_3:Int = 0x4b;

	public static function pack(payload:Bytes, ?version:Int = CURRENT_VERSION, ?flags:Int = 0):Bytes {
		if (payload == null)
			throw new MessagePackError("MessagePack frame payload cannot be null");
		checkByte(version, "version");
		checkByte(flags, "flags");
		if (flags != 0)
			throw new MessagePackError("Unsupported MessagePack frame flags");
		var frame = Bytes.alloc(HEADER_BYTES + payload.length);
		frame.set(0, MAGIC_0);
		frame.set(1, MAGIC_1);
		frame.set(2, MAGIC_2);
		frame.set(3, MAGIC_3);
		frame.set(4, version);
		frame.set(5, flags);
		frame.set(6, (payload.length >>> 24) & 0xff);
		frame.set(7, (payload.length >>> 16) & 0xff);
		frame.set(8, (payload.length >>> 8) & 0xff);
		frame.set(9, payload.length & 0xff);
		for (index in 0...payload.length)
			frame.set(HEADER_BYTES + index, payload.get(index));
		return frame;
	}

	public static function unpack(frame:Bytes, ?expectedVersion:Int = CURRENT_VERSION, ?maxPayload:Int = MessagePackReader.DEFAULT_MAX_BYTES):Bytes {
		if (frame == null)
			throw new MessagePackError("MessagePack frame cannot be null");
		checkByte(expectedVersion, "expected version");
		if (maxPayload < 0)
			throw new MessagePackError("MessagePack frame limit cannot be negative");
		if (frame.length < HEADER_BYTES)
			throw new MessagePackError("MessagePack frame is truncated");
		if (frame.get(0) != MAGIC_0 || frame.get(1) != MAGIC_1 || frame.get(2) != MAGIC_2 || frame.get(3) != MAGIC_3)
			throw new MessagePackError("Invalid MessagePack frame magic");
		if (frame.get(4) != expectedVersion)
			throw new MessagePackError("Unsupported MessagePack frame version");
		if (frame.get(5) != 0)
			throw new MessagePackError("Unsupported MessagePack frame flags");
		var length = frame.get(6) * 0x1000000 + frame.get(7) * 0x10000 + frame.get(8) * 0x100 + frame.get(9);
		if (length > maxPayload)
			throw new MessagePackError("MessagePack frame payload exceeds configured limit");
		if (frame.length != HEADER_BYTES + length)
			throw new MessagePackError("MessagePack frame length mismatch");
		var payload = Bytes.alloc(length);
		for (index in 0...length)
			payload.set(index, frame.get(HEADER_BYTES + index));
		return payload;
	}

	static function checkByte(value:Int, name:String):Void {
		if (value < 0 || value > 0xff)
			throw new MessagePackError('MessagePack frame $name must fit in one byte');
	}
}
