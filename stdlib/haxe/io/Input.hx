package haxe.io;

/**
 * A stream of bytes to read, as in Haxe. A subclass reads one byte with `readByte`, which throws `haxe.io.Eof` at the end,
 * and may read many at once by overriding `readBytes`; everything else is built on them.
 */
class Input {
	/** Whether multi-byte numbers are read most significant byte first. */
	public var bigEndian:Bool = false;

	/** The next byte, from 0 to 255. Throws `haxe.io.Eof` at the end of the input. */
	public function readByte():Int
		throw "Input.readByte is not implemented";

	/** Reads up to `len` bytes into `s` at `pos` and returns how many it read; fewer only at the end of the input. */
	public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw Error.OutsideBounds;
		var k = len;
		try {
			while (k > 0) {
				s.set(pos, readByte());
				pos++;
				k--;
			}
		} catch (_:Eof) {}
		return len - k;
	}

	/** Closes the input, releasing what it reads from. It reads nothing after. */
	public function close():Void {}

	/** Everything to the end of the input. */
	public function readAll(?bufsize:Int):Bytes {
		var size = bufsize == null ? 1 << 14 : bufsize;
		var buffer = Bytes.alloc(size), total = new BytesBuffer();
		try {
			while (true) {
				var count = readBytes(buffer, 0, size);
				if (count == 0)
					throw Error.Blocked;
				total.addBytes(buffer, 0, count);
			}
		} catch (_:Eof) {}
		return total.getBytes();
	}

	/** Reads exactly `len` bytes into `s` at `pos`; throws `haxe.io.Eof` if the input ends first. */
	public function readFullBytes(s:Bytes, pos:Int, len:Int):Void {
		while (len > 0) {
			var count = readBytes(s, pos, len);
			if (count == 0)
				throw Error.Blocked;
			pos += count;
			len -= count;
		}
	}

	/** Exactly `nbytes` bytes. */
	public function read(nbytes:Int):Bytes {
		var s = Bytes.alloc(nbytes), pos = 0;
		while (nbytes > 0) {
			var count = readBytes(s, pos, nbytes);
			if (count == 0)
				throw Error.Blocked;
			pos += count;
			nbytes -= count;
		}
		return s;
	}

	/** The bytes up to the first `end` byte, which is read but not returned. */
	public function readUntil(end:Int):String {
		var buffer = new BytesBuffer(), last:Int;
		while ((last = readByte()) != end)
			buffer.addByte(last);
		return buffer.getBytes().toString();
	}

	/** A line without its "\n" or "\r\n"; throws `haxe.io.Eof` when nothing is left. */
	public function readLine():String {
		var buffer = new BytesBuffer(), last:Int, line:String;
		try {
			while ((last = readByte()) != "\n".code)
				buffer.addByte(last);
			line = buffer.getBytes().toString();
			if (line.length > 0 && StringTools.fastCodeAt(line, line.length - 1) == "\r".code)
				line = line.substr(0, line.length - 1);
		} catch (end:Eof) {
			line = buffer.getBytes().toString();
			if (line.length == 0)
				throw end;
		}
		return line;
	}

	/** A 32-bit IEEE float, in the input's byte order. */
	public function readFloat():Float
		return FPHelper.i32ToFloat(readInt32());

	/** A 64-bit IEEE float, in the input's byte order. */
	public function readDouble():Float {
		var first = readInt32(), second = readInt32();
		return bigEndian ? FPHelper.i64ToDouble(second, first) : FPHelper.i64ToDouble(first, second);
	}

	/** A signed byte, from -128 to 127. */
	public function readInt8():Int {
		var n = readByte();
		return n >= 128 ? n - 256 : n;
	}

	/** A signed 16-bit integer, in the input's byte order. */
	public function readInt16():Int {
		var n = readUInt16();
		return n & 0x8000 != 0 ? n - 0x10000 : n;
	}

	/** An unsigned 16-bit integer, in the input's byte order. */
	public function readUInt16():Int {
		var first = readByte(), second = readByte();
		return bigEndian ? second | (first << 8) : first | (second << 8);
	}

	/** A signed 24-bit integer, in the input's byte order. */
	public function readInt24():Int {
		var n = readUInt24();
		return n & 0x800000 != 0 ? n - 0x1000000 : n;
	}

	/** An unsigned 24-bit integer, in the input's byte order. */
	public function readUInt24():Int {
		var first = readByte(), second = readByte(), third = readByte();
		return bigEndian ? third | (second << 8) | (first << 16) : first | (second << 8) | (third << 16);
	}

	/** A signed 32-bit integer, in the input's byte order. */
	public function readInt32():Int {
		var first = readByte(), second = readByte(), third = readByte(), fourth = readByte();
		return bigEndian ? fourth | (third << 8) | (second << 16) | (first << 24) : first | (second << 8)
			| (third << 16) | (fourth << 24);
	}

	/** `len` bytes as a String in `encoding`, UTF-8 by default (`Bytes.getString`). */
	public function readString(len:Int, ?encoding:Encoding):String {
		var bytes = Bytes.alloc(len);
		readFullBytes(bytes, 0, len);
		return bytes.getString(0, len, encoding);
	}
}
