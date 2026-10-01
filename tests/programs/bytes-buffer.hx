// haxe.io.BytesBuffer collects bytes, strings and numbers and hands back the Bytes.
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

function main():Int {
	var buffer = new BytesBuffer();
	buffer.addByte(65);
	buffer.addString("BC");
	buffer.add(Bytes.ofString("DE"));
	buffer.addBytes(Bytes.ofString("xFGHy"), 1, 3);
	var lengthBefore = buffer.length;
	buffer.addInt32(0x01020304);
	var bytes = buffer.getBytes();
	var checks = [
		lengthBefore == 8,
		buffer.length == 12,
		bytes.length == 12,
		bytes.toString().substr(0, 8) == "ABCDEFGH",
		bytes.get(8) == 4,
		bytes.get(11) == 1
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
