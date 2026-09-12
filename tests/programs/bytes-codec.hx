import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

function main():Int {
	var output = new BytesOutput();
	output.bigEndian = false;
	output.writeByte(7);
	output.writeInt32(35);
	output.writeDouble(1.5);
	output.writeString("ok");
	if (output.writeBytes(Bytes.ofString("xyz!"), 3, 1) != 1)
		return 1;
	var bytes = output.getBytes();
	if (bytes.length != 16 || bytes.get(0) != 7 || bytes.sub(13, 3).compare(Bytes.ofString("ok!")) != 0)
		return 1;
	var input = new BytesInput(bytes);
	input.bigEndian = false;
	if (input.readByte() != 7 || input.readInt32() != 35 || input.readDouble() != 1.5 || input.readString(3) != "ok!")
		return 2;
	return input.position == bytes.length ? 42 : 3;
}
