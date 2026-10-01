package haxe.io;

/** Byte accumulation over the shared byte-output ABI; returned bytes are independent snapshots. */
class BytesBuffer {
	final output:BytesOutput;

	public var length(default, null):Int = 0;

	public function new() {
		output = new BytesOutput();
		output.setBigEndian(false);
	}

	public function addByte(value:Int):Void {
		output.writeByte(value);
		length++;
	}

	public function add(bytes:Bytes):Void {
		output.write(bytes);
		length += bytes.length;
	}

	public function addBytes(bytes:Bytes, position:Int, count:Int):Void {
		if (position < 0 || count < 0 || position > bytes.length - count)
			throw "BytesBuffer.addBytes range is out of bounds";
		output.writeBytes(bytes, position, count);
		length += count;
	}

	public function addInt32(value:Int):Void {
		output.writeInt32(value);
		length += 4;
	}

	public function addDouble(value:Float):Void {
		output.writeDouble(value);
		length += 8;
	}

	public function getBytes():Bytes
		return output.getBytes();
}
