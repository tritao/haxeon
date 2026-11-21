package haxe.io;

/**
 * A stream of bytes to write, as in Haxe. A subclass writes one byte with `writeByte` and may write many at once by overriding
 * `writeBytes`; everything else is built on them.
 */
class Output {
	/** Whether multi-byte numbers are written most significant byte first. */
	public var bigEndian:Bool = false;

	public function writeByte(c:Int):Void
		throw "Output.writeByte is not implemented";

	/** Writes up to `len` bytes of `s` from `pos` and returns how many it wrote. */
	public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw Error.OutsideBounds;
		var k = len;
		while (k > 0) {
			writeByte(s.get(pos));
			pos++;
			k--;
		}
		return len;
	}

	public function flush():Void {}

	public function close():Void {}

	public function write(s:Bytes):Void {
		var left = s.length, pos = 0;
		while (left > 0) {
			var count = writeBytes(s, pos, left);
			if (count == 0)
				throw Error.Blocked;
			pos += count;
			left -= count;
		}
	}

	/** Writes exactly `len` bytes of `s` from `pos`. */
	public function writeFullBytes(s:Bytes, pos:Int, len:Int):Void {
		while (len > 0) {
			var count = writeBytes(s, pos, len);
			pos += count;
			len -= count;
		}
	}

	public function writeFloat(x:Float):Void
		writeInt32(FPHelper.floatToI32(x));

	public function writeDouble(x:Float):Void {
		var bits = FPHelper.doubleToI64(x),
			low = haxe.Int64.toInt(bits),
			high = haxe.Int64.toInt(haxe.Int64.shr(bits, 32));
		if (bigEndian) {
			writeInt32(high);
			writeInt32(low);
		} else {
			writeInt32(low);
			writeInt32(high);
		}
	}

	public function writeInt8(x:Int):Void {
		if (x < -0x80 || x >= 0x80)
			throw Error.Overflow;
		writeByte(x & 0xFF);
	}

	public function writeInt16(x:Int):Void {
		if (x < -0x8000 || x >= 0x8000)
			throw Error.Overflow;
		writeUInt16(x & 0xFFFF);
	}

	public function writeUInt16(x:Int):Void {
		if (x < 0 || x >= 0x10000)
			throw Error.Overflow;
		if (bigEndian) {
			writeByte(x >> 8);
			writeByte(x & 0xFF);
		} else {
			writeByte(x & 0xFF);
			writeByte(x >> 8);
		}
	}

	public function writeInt24(x:Int):Void {
		if (x < -0x800000 || x >= 0x800000)
			throw Error.Overflow;
		writeUInt24(x & 0xFFFFFF);
	}

	public function writeUInt24(x:Int):Void {
		if (x < 0 || x >= 0x1000000)
			throw Error.Overflow;
		if (bigEndian) {
			writeByte(x >> 16);
			writeByte((x >> 8) & 0xFF);
			writeByte(x & 0xFF);
		} else {
			writeByte(x & 0xFF);
			writeByte((x >> 8) & 0xFF);
			writeByte(x >> 16);
		}
	}

	public function writeInt32(x:Int):Void {
		if (bigEndian) {
			writeByte(x >>> 24);
			writeByte((x >> 16) & 0xFF);
			writeByte((x >> 8) & 0xFF);
			writeByte(x & 0xFF);
		} else {
			writeByte(x & 0xFF);
			writeByte((x >> 8) & 0xFF);
			writeByte((x >> 16) & 0xFF);
			writeByte(x >>> 24);
		}
	}

	/** Writes `s` in `encoding`, UTF-8 by default (`Bytes.ofString`). */
	public function writeString(s:String, ?encoding:Encoding):Void {
		var bytes = Bytes.ofString(s, encoding);
		writeFullBytes(bytes, 0, bytes.length);
	}
}
