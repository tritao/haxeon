package haxe.io;

/**
 * A stream of bytes to write, as in Haxe. A subclass writes one byte with `writeByte` and may write many at once by overriding
 * `writeBytes`; everything else is built on them.
 */
class Output {
	/** Whether multi-byte numbers are written most significant byte first. */
	public var bigEndian:Bool = false;

	/** Writes the byte `c`, its low 8 bits. */
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

	/** Writes out what the output buffers, if it buffers. */
	public function flush():Void {}

	/** Flushes and closes the output, releasing what it writes to. It writes nothing after. */
	public function close():Void {}

	/** Writes all of `s`. */
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

	/** Writes `x` as a 32-bit IEEE float, in the output's byte order. */
	public function writeFloat(x:Float):Void
		writeInt32(FPHelper.floatToI32(x));

	/** Writes `x` as a 64-bit IEEE float, in the output's byte order. */
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

	/** Writes `x` as a signed byte. Throws `Error.Overflow` outside -128 to 127. */
	public function writeInt8(x:Int):Void {
		if (x < -0x80 || x >= 0x80)
			throw Error.Overflow;
		writeByte(x & 0xFF);
	}

	/**
	 * Writes `x` as a signed 16-bit integer, in the output's byte order. Throws `Error.Overflow` when it does not fit.
	 */
	public function writeInt16(x:Int):Void {
		if (x < -0x8000 || x >= 0x8000)
			throw Error.Overflow;
		writeUInt16(x & 0xFFFF);
	}

	/**
	 * Writes `x` as an unsigned 16-bit integer, in the output's byte order. Throws `Error.Overflow` when it does not
	 * fit.
	 */
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

	/**
	 * Writes `x` as a signed 24-bit integer, in the output's byte order. Throws `Error.Overflow` when it does not fit.
	 */
	public function writeInt24(x:Int):Void {
		if (x < -0x800000 || x >= 0x800000)
			throw Error.Overflow;
		writeUInt24(x & 0xFFFFFF);
	}

	/**
	 * Writes `x` as an unsigned 24-bit integer, in the output's byte order. Throws `Error.Overflow` when it does not
	 * fit.
	 */
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

	/** Writes `x` as a signed 32-bit integer, in the output's byte order. */
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
