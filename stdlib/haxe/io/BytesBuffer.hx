/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** An append-only buffer of bytes: build a `Bytes` from pieces, then take it with `getBytes`. */
class BytesBuffer {
	var output:BytesOutput;
	var size:Int = 0;

	/** The number of bytes added so far. */
	public var length(get, never):Int;

	public function new() {
		output = new BytesOutput();
		// Haxe's BytesBuffer writes numbers little-endian.
		output.setBigEndian(false);
	}

	function get_length():Int
		return size;

	public function addByte(byte:Int):Void {
		output.writeByte(byte);
		size++;
	}

	public function add(src:Bytes):Void {
		output.write(src);
		size += src.length;
	}

	public function addString(value:String, ?encoding:Encoding):Void
		add(Bytes.ofString(value));

	public function addInt32(value:Int):Void {
		output.writeInt32(value);
		size += 4;
	}

	public function addDouble(value:Float):Void {
		output.writeDouble(value);
		size += 8;
	}

	public function addBytes(src:Bytes, pos:Int, len:Int):Void {
		if (pos < 0 || len < 0 || pos + len > src.length)
			throw "Out of bounds";
		output.writeBytes(src, pos, len);
		size += len;
	}

	public function getBytes():Bytes
		return output.getBytes();
}
