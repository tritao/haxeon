package runtime;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Host-owned, versioned serialized state passed between plugin generations. */
class RuntimeStateEnvelope {
	public static inline final VERSION = 1;

	public final payload:String;

	public function new(payload:String)
		this.payload = Bytes.ofString(payload).toString();

	public function encode():Bytes {
		var payloadBytes = Bytes.ofString(payload), output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("RST");
		output.writeByte(VERSION);
		output.writeInt32(payloadBytes.length);
		output.write(payloadBytes);
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):RuntimeStateEnvelope {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "RST" || input.readByte() != VERSION)
				throw "Unsupported runtime state envelope";
			var length = input.readInt32();
			if (length < 0 || length > bytes.length - input.position)
				throw "Invalid runtime state payload length";
			var result = new RuntimeStateEnvelope(input.readString(length));
			if (input.position != bytes.length)
				throw "Trailing runtime state data";
			return result;
		} catch (_:haxe.io.Eof) {
			throw "Truncated runtime state envelope";
		}
	}
}
