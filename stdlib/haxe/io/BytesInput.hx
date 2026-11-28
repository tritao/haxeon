/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** An input reading a range of a `Bytes` in place, as in Haxe; reading past its end throws `haxe.io.Eof`. */
class BytesInput extends Input {
	final b:Bytes;
	final totlen:Int;
	var pos:Int;
	var len:Int;

	/** The read position, from the start of `b`. */
	public var position(get, set):Int;

	/** The length of the range read. */
	public var length(get, never):Int;

	/**
	 * An input reading `len` bytes of `b` from `pos`: by default all of it. Throws `Error.OutsideBounds` when the range
	 * is not in `b`.
	 */
	public function new(b:Bytes, ?pos:Int, ?len:Int) {
		var start = pos == null ? 0 : pos;
		var count = len == null ? b.length - start : len;
		if (start < 0 || count < 0 || start + count > b.length)
			throw Error.OutsideBounds;
		this.b = b;
		this.pos = start;
		this.len = count;
		this.totlen = count;
	}

	function get_position():Int
		return pos;

	function get_length():Int
		return totlen;

	function set_position(p:Int):Int {
		var target = p < 0 ? 0 : p > totlen ? totlen : p;
		len = totlen - target;
		return pos = target;
	}

	override public function readByte():Int {
		if (len == 0)
			throw new Eof();
		len--;
		return b.get(pos++);
	}

	override public function readBytes(buf:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw Error.OutsideBounds;
		if (this.len == 0 && len > 0)
			throw new Eof();
		var count = this.len < len ? this.len : len;
		buf.blit(pos, b, this.pos, count);
		this.pos += count;
		this.len -= count;
		return count;
	}

	override public function readInt32():Int {
		if (len < 4)
			throw new Eof();
		var value = b.getInt32(pos);
		pos += 4;
		len -= 4;
		return bigEndian ? (value >>> 24) | ((value >> 8) & 0xFF00) | ((value << 8) & 0xFF0000) | (value << 24) : value;
	}

	override public function readString(count:Int, ?encoding:Encoding):String {
		if (count < 0)
			throw Error.OutsideBounds;
		if (len < count)
			throw new Eof();
		var text = b.getString(pos, count, Encoding.stdEncoding(encoding));
		pos += count;
		len -= count;
		return text;
	}

	override public function read(nbytes:Int):Bytes {
		if (nbytes < 0)
			throw Error.OutsideBounds;
		if (len < nbytes)
			throw new Eof();
		var bytes = b.sub(pos, nbytes);
		pos += nbytes;
		len -= nbytes;
		return bytes;
	}
}
