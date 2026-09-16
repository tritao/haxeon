package haxe.wire;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.wire.MessagePackError;

typedef MessagePackExtension = {
	final type:Int;
	final value:Bytes;
}

/**
	Bounded MessagePack reader for typed codecs.

	It consumes only the primitive shapes needed by a generated codec and also
	provides skip() for forward-compatible unknown fields.
 */
class MessagePackReader {
	public static inline final DEFAULT_MAX_BYTES:Int = 16 * 1024 * 1024;
	public static inline final DEFAULT_MAX_CONTAINER:Int = 1000000;
	public static inline final DEFAULT_MAX_DEPTH:Int = 64;

	final input:BytesInput;
	final totalBytes:Int;
	final maxContainer:Int;
	final maxDepth:Int;
	final maxBytes:Int;
	var bufferedMarker:Null<Int>;

	public function new(bytes:Bytes, ?maxContainer:Int = DEFAULT_MAX_CONTAINER, ?maxDepth:Int = DEFAULT_MAX_DEPTH, ?maxBytes:Int = DEFAULT_MAX_BYTES) {
		if (bytes == null)
			throw new MessagePackError("MessagePack input cannot be null");
		if (maxContainer < 0 || maxDepth < 0 || maxBytes < 0)
			throw new MessagePackError("MessagePack reader limits cannot be negative");
		this.input = new BytesInput(bytes);
		this.input.bigEndian = true;
		this.totalBytes = bytes.length;
		this.maxContainer = maxContainer;
		this.maxDepth = maxDepth;
		this.maxBytes = maxBytes;
		this.bufferedMarker = null;
		if (totalBytes > maxBytes)
			throw new MessagePackError("MessagePack input exceeds configured limit");
	}

	public function position():Int
		return input.position - (bufferedMarker == null ? 0 : 1);

	public function atEnd():Bool
		return bufferedMarker == null && input.position == totalBytes;

	/** Returns whether the next value is nil without consuming it. */
	public function isNil():Bool {
		if (bufferedMarker != null)
			return bufferedMarker == 0xc0;
		if (input.position >= totalBytes)
			return false;
		bufferedMarker = input.readByte();
		return bufferedMarker == 0xc0;
	}

	public function readNil():Void
		expect(0xc0, "nil");

	public function readBool():Bool {
		var marker = readByte();
		if (marker == 0xc2)
			return false;
		if (marker == 0xc3)
			return true;
		unexpected(marker, "boolean");
	}

	public function readInt():Int {
		var marker = readByte();
		if (marker <= 0x7f)
			return marker;
		if (marker >= 0xe0)
			return marker - 0x100;
		switch marker {
			case 0xcc:
				return readUInt8();
			case 0xcd:
				return readUInt16();
			case 0xce:
				var value = input.readInt32();
				if (value < 0)
					throw new MessagePackError("MessagePack uint32 does not fit in Haxe Int");
				return value;
			case 0xd0:
				return signedByte(readByte());
			case 0xd1:
				return signed16(readUInt16());
			case 0xd2:
				return input.readInt32();
			case 0xcf, 0xd3:
				throw new MessagePackError("MessagePack Int64 requires a typed Int64 codec");
			default:
				unexpected(marker, "integer");
		}
	}

	public function readFloat():Float {
		var marker = readByte();
		if (marker == 0xca)
			return decodeFloat32(input.readInt32());
		if (marker == 0xcb)
			return input.readDouble();
		throw new MessagePackError('Expected MessagePack float, got marker 0x${StringTools.hex(marker, 2)}');
	}

	/** Decode IEEE-754 binary32 without adding a target-specific byte ABI. */
	function decodeFloat32(bits:Int):Float {
		var sign = (bits >>> 31) == 0 ? 1.0 : -1.0,
			exponent = (bits >>> 23) & 0xff,
			fraction = bits & 0x7fffff;
		if (exponent == 0xff)
			return fraction == 0 ? sign * (1.0 / 0.0) : 0.0 / 0.0;
		if (exponent == 0)
			return sign * (fraction / 8388608.0) * Math.pow(2.0, -126.0);
		return sign * (1.0 + fraction / 8388608.0) * Math.pow(2.0, exponent - 127.0);
	}

	public function readString():String {
		var length = readLength(readByte(), 31, 0xa0, 0xd9, 0xda, 0xdb, "string");
		return readStringBytes(length);
	}

	public function readBinary():Bytes {
		var length = readLength(readByte(), -1, -1, 0xc4, 0xc5, 0xc6, "binary");
		return readBytes(length);
	}

	public function readArrayHeader():Int
		return readLength(readByte(), 15, 0x90, -1, 0xdc, 0xdd, "array");

	public function readMapHeader():Int
		return readLength(readByte(), 15, 0x80, -1, 0xde, 0xdf, "map");

	public function readExtension():MessagePackExtension {
		var marker = readByte(), length:Int;
		switch marker {
			case 0xd4:
				length = 1;
			case 0xd5:
				length = 2;
			case 0xd6:
				length = 4;
			case 0xd7:
				length = 8;
			case 0xd8:
				length = 16;
			case 0xc7:
				length = checkedLength(readUInt8(), "extension");
			case 0xc8:
				length = checkedLength(readUInt16(), "extension");
			case 0xc9:
				length = readLength32("extension");
			default:
				unexpected(marker, "extension");
		}
		var type = signedByte(readByte());
		return {type: type, value: readBytes(length)};
	}

	/** Skips one complete value, including nested arrays, maps, or extensions. */
	public function skip():Void
		skipValue(0);

	function skipValue(depth:Int):Void {
		if (depth > maxDepth)
			throw new MessagePackError("MessagePack nesting exceeds configured limit");
		var marker = readByte();
		if (marker <= 0x7f || marker >= 0xe0 || marker == 0xc0 || marker == 0xc2 || marker == 0xc3)
			return;
		if (marker >= 0xa0 && marker <= 0xbf) {
			skipBytes(marker - 0xa0);
			return;
		}
		if (marker >= 0x90 && marker <= 0x9f) {
			skipItems(marker - 0x90, depth + 1, false);
			return;
		}
		if (marker >= 0x80 && marker <= 0x8f) {
			skipItems(marker - 0x80, depth + 1, true);
			return;
		}
		switch marker {
			case 0xcc:
				skipBytes(1);
			case 0xcd:
				skipBytes(2);
			case 0xce, 0xd2:
				skipBytes(4);
			case 0xcf, 0xd3, 0xcb:
				skipBytes(8);
			case 0xca:
				skipBytes(4);
			case 0xd0:
				skipBytes(1);
			case 0xd1:
				skipBytes(2);
			case 0xd9:
				skipBytes(readUInt8());
			case 0xda:
				skipBytes(readUInt16());
			case 0xdb:
				skipBytes(readLength32("string"));
			case 0xc4:
				skipBytes(readUInt8());
			case 0xc5:
				skipBytes(readUInt16());
			case 0xc6:
				skipBytes(readLength32("binary"));
			case 0xdc:
				skipItems(readUInt16(), depth + 1, false);
			case 0xdd:
				skipItems(readLength32("array"), depth + 1, false);
			case 0xde:
				skipItems(readUInt16(), depth + 1, true);
			case 0xdf:
				skipItems(readLength32("map"), depth + 1, true);
			case 0xd4:
				skipBytes(2);
			case 0xd5:
				skipBytes(3);
			case 0xd6:
				skipBytes(5);
			case 0xd7:
				skipBytes(9);
			case 0xd8:
				skipBytes(17);
			case 0xc7:
				skipBytes(readUInt8() + 1);
			case 0xc8:
				skipBytes(readUInt16() + 1);
			case 0xc9:
				skipBytes(readLength32("extension") + 1);
			default:
				throw new MessagePackError('Unsupported MessagePack marker 0x${StringTools.hex(marker, 2)}');
		}
	}

	function skipItems(count:Int, depth:Int, map:Bool):Void {
		checkContainer(count);
		if (map && count > 0x3fffffff)
			throw new MessagePackError("MessagePack map is too large");
		var total = map ? count * 2 : count;
		for (_ in 0...total)
			skipValue(depth);
	}

	function readLength(marker:Int, fixedLimit:Int, fixedBase:Int, smallTag:Int, mediumTag:Int, largeTag:Int, kind:String):Int {
		if (fixedBase >= 0 && marker >= fixedBase && marker <= fixedBase + fixedLimit)
			return marker - fixedBase;
		if (marker == smallTag)
			return checkedLength(readUInt8(), kind);
		if (marker == mediumTag)
			return checkedLength(readUInt16(), kind);
		if (marker == largeTag)
			return readLength32(kind);
		unexpected(marker, kind);
	}

	function readLength32(kind:String):Int {
		var value = input.readInt32();
		if (value < 0)
			throw new MessagePackError('MessagePack $kind length does not fit in Haxe Int');
		return checkedLength(value, kind);
	}

	function checkedLength(value:Int, kind:String):Int {
		if (value < 0 || value > maxBytes || value > totalBytes - input.position)
			throw new MessagePackError('Invalid MessagePack $kind length');
		if ((kind == "array" || kind == "map") && value > maxContainer)
			throw new MessagePackError('MessagePack $kind exceeds configured limit');
		return value;
	}

	function readStringBytes(length:Int):String {
		if (length == 0)
			return "";
		return input.readString(length);
	}

	function readBytes(length:Int):Bytes
		return input.read(length);

	function skipBytes(length:Int):Void {
		if (length < 0 || length > totalBytes - input.position)
			throw new MessagePackError("Truncated MessagePack value");
		input.read(length);
	}

	function readUInt8():Int
		return input.readByte();

	function readUInt16():Int
		return (input.readByte() << 8) | input.readByte();

	function signedByte(value:Int):Int
		return value >= 0x80 ? value - 0x100 : value;

	function signed16(value:Int):Int
		return value >= 0x8000 ? value - 0x10000 : value;

	function checkContainer(count:Int):Void
		if (count < 0 || count > maxContainer)
			throw new MessagePackError("MessagePack container exceeds configured limit");

	function readByte():Int {
		if (bufferedMarker != null) {
			var marker = bufferedMarker;
			bufferedMarker = null;
			return cast marker;
		}
		if (input.position >= totalBytes)
			throw new MessagePackError("Truncated MessagePack value");
		return input.readByte();
	}

	function expect(expected:Int, kind:String):Void {
		var marker = readByte();
		if (marker != expected)
			unexpected(marker, kind);
	}

	function unexpected(marker:Int, expected:String):Void
		throw new MessagePackError('Expected MessagePack $expected, got marker 0x${StringTools.hex(marker, 2)}');
}
