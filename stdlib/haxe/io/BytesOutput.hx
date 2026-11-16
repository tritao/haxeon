/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** An output collecting what is written into a `Bytes`, as in Haxe; `getBytes` takes it, after which nothing is written. */
class BytesOutput extends Output {
	final b = new BytesBuffer();

	/** The number of bytes written so far. */
	public var length(get, never):Int;

	public function new() {}

	function get_length():Int
		return b.length;

	override public function writeByte(c:Int):Void
		b.addByte(c);

	override public function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		b.addBytes(buf, pos, len);
		return len;
	}

	override public function writeInt32(x:Int):Void
		if (bigEndian)
			super.writeInt32(x)
				else b.addInt32(x);

	override public function writeString(s:String, ?encoding:Encoding):Void
		b.addString(s);

	/** The bytes written, without copying them. */
	public function getBytes():Bytes
		return b.getBytes();
}
