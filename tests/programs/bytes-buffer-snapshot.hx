import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;

function main():Int {
	var unicode = new BytesBuffer();
	for (value in [0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80])
		unicode.addByte(value);
	if (unicode.length != 6 || unicode.getBytes().toString() != "é😀")
		return 1;
	var source = Bytes.alloc(3);
	source.set(0, 65);
	source.set(1, 0);
	source.set(2, 255);
	var binary = new BytesBuffer();
	binary.add(source);
	binary.addBytes(source, 1, 2);
	binary.addByte(0x141);
	var failed = false;
	try
		binary.addBytes(source, -1, 1)
	catch (_:Dynamic)
		failed = true;
	if (!failed || binary.length != 6)
		return 2;
	var snapshot = binary.getBytes();
	if (snapshot.length != 6 || snapshot.get(1) != 0 || snapshot.get(4) != 255 || snapshot.get(5) != 65)
		return 3;
	binary.addByte(90);
	if (snapshot.length != 6 || binary.length != 7 || binary.getBytes().get(6) != 90)
		return 4;
	var numeric = new BytesBuffer();
	numeric.addInt32(0x12345678);
	numeric.addDouble(-2.25);
	if (numeric.length != 12 || numeric.getBytes().get(0) != 0x78)
		return 5;
	var input = new BytesInput(numeric.getBytes());
	input.bigEndian = false;
	if (input.readInt32() != 0x12345678 || input.readDouble() != -2.25)
		return 6;
	var growing = new BytesBuffer();
	for (index in 0...4097)
		growing.addByte(index);
	return growing.length == 4097 && growing.getBytes().get(4095) == 255 ? 42 : 7;
}
