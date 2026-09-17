package haxe.wire;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.wire.MessagePackError;

/**
	Small, deterministic MessagePack writer for typed codecs.

	The writer deliberately exposes format primitives instead of accepting
	Dynamic values. Generated codecs can therefore select the exact wire shape
	without reflection or intermediate object graphs.
 */
class MessagePackWriter {
	public static inline final DEFAULT_MAX_BYTES:Int = 16 * 1024 * 1024;

	final output:BytesOutput;
	final maxBytes:Int;
	var size:Int;

	public function new(?maxBytes:Int = DEFAULT_MAX_BYTES) {
		if (maxBytes < 0)
			throw new MessagePackError("MessagePack writer limit cannot be negative");
		this.output = new BytesOutput();
		this.output.bigEndian = true;
		this.maxBytes = maxBytes;
		this.size = 0;
	}

	public function writeNil():Void
		writeByte(0xc0);

	public function writeBool(value:Bool):Void
		writeByte(value ? 0xc3 : 0xc2);

	/** Writes a Haxe Int using MessagePack's smallest signed representation. */
	public function writeInt(value:Int):Void {
		if (value >= 0) {
			if (value <= 0x7f)
				writeByte(value);
			else if (value <= 0xff) {
				writeByte(0xcc);
				writeByte(value);
			} else if (value <= 0xffff) {
				writeByte(0xcd);
				writeUInt16(value);
			} else {
				writeByte(0xce);
				writeUInt32(value);
			}
		} else if (value >= -32) {
			writeByte(0x100 + value);
		} else if (value >= -0x80) {
			writeByte(0xd0);
			writeByte(value);
		} else if (value >= -0x8000) {
			writeByte(0xd1);
			writeUInt16(value);
		} else {
			writeByte(0xd2);
			writeUInt32(value);
		}
	}

	/** Writes a signed Haxe Int64 using the smallest MessagePack integer shape. */
	public function writeInt64(value:haxe.Int64):Void {
		var minimum = haxe.Int64.ofInt(-2147483648),
			maximum = haxe.Int64.ofInt(2147483647),
			uint32Maximum = haxe.Int64.parseString("4294967295");
		if (haxe.Int64.compare(value, minimum) >= 0 && haxe.Int64.compare(value, maximum) <= 0) {
			writeInt(haxe.Int64.toInt(value));
			return;
		}
		if (haxe.Int64.compare(value, maximum) > 0 && haxe.Int64.compare(value, uint32Maximum) <= 0) {
			writeByte(0xce);
			writeUInt32(haxe.Int64.toInt(value));
			return;
		}
		writeByte(0xd3);
		reserve(8);
		output.writeInt32(haxe.Int64.toInt(haxe.Int64.ushr(value, 32)));
		output.writeInt32(haxe.Int64.toInt(value));
	}

	/** Writes a MessagePack float64 value. */
	public function writeFloat(value:Float):Void {
		writeByte(0xcb);
		reserve(8);
		output.writeDouble(value);
	}

	public function writeString(value:String):Void {
		if (value == null)
			throw new MessagePackError("MessagePack string cannot be null; writeNil instead");
		var bytes = Bytes.ofString(value);
		writeLength(bytes.length, 31, 0xa0, 0xd9, 0xda, 0xdb);
		writeBytes(bytes);
	}

	public function writeBinary(value:Bytes):Void {
		if (value == null)
			throw new MessagePackError("MessagePack binary value cannot be null; writeNil instead");
		writeLength(value.length, -1, -1, 0xc4, 0xc5, 0xc6);
		writeBytes(value);
	}

	public function writeArrayHeader(count:Int):Void {
		if (count < 0)
			throw new MessagePackError("MessagePack array count cannot be negative");
		writeLength(count, 15, 0x90, -1, 0xdc, 0xdd);
	}

	public function writeMapHeader(count:Int):Void {
		if (count < 0)
			throw new MessagePackError("MessagePack map count cannot be negative");
		writeLength(count, 15, 0x80, -1, 0xde, 0xdf);
	}

	/** Writes an application-defined extension value. */
	public function writeExtension(type:Int, value:Bytes):Void {
		if (type < -128 || type > 127)
			throw new MessagePackError("MessagePack extension type must fit in Int8");
		if (value == null)
			throw new MessagePackError("MessagePack extension payload cannot be null");
		var length = value.length;
		switch length {
			case 1:
				writeByte(0xd4);
			case 2:
				writeByte(0xd5);
			case 4:
				writeByte(0xd6);
			case 8:
				writeByte(0xd7);
			case 16:
				writeByte(0xd8);
			default:
				if (length <= 0xff) {
					writeByte(0xc7);
					writeByte(length);
				} else if (length <= 0xffff) {
					writeByte(0xc8);
					writeUInt16(length);
				} else {
					writeByte(0xc9);
					writeUInt32(length);
				}
		}
		writeByte(type);
		writeBytes(value);
	}

	public function getBytes():Bytes
		return output.getBytes();

	public function byteLength():Int
		return size;

	function writeLength(length:Int, fixedLimit:Int, fixedBase:Int, smallTag:Int, mediumTag:Int, largeTag:Int):Void {
		if (length < 0)
			throw new MessagePackError("MessagePack length cannot be negative");
		if (fixedBase >= 0 && length <= fixedLimit) {
			writeByte(fixedBase | length);
		} else if (smallTag >= 0 && length <= 0xff) {
			writeByte(smallTag);
			writeByte(length);
		} else if (mediumTag >= 0 && length <= 0xffff) {
			writeByte(mediumTag);
			writeUInt16(length);
		} else {
			writeByte(largeTag);
			writeUInt32(length);
		}
	}

	function writeBytes(value:Bytes):Void {
		reserve(value.length);
		if (value.length > 0)
			output.write(value);
	}

	function writeUInt16(value:Int):Void {
		writeByte(value >>> 8);
		writeByte(value);
	}

	function writeUInt32(value:Int):Void {
		writeByte(value >>> 24);
		writeByte(value >>> 16);
		writeByte(value >>> 8);
		writeByte(value);
	}

	function writeByte(value:Int):Void {
		reserve(1);
		output.writeByte(value);
	}

	function reserve(amount:Int):Void {
		if (amount < 0 || size > maxBytes - amount)
			throw new MessagePackError("MessagePack output exceeds configured limit");
		size += amount;
	}
}
