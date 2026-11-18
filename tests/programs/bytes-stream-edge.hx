import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.Eof;

// BytesOutput and BytesInput behave as Haxe's: little-endian by default, the input reads its bytes in place within the
// range it was given, reading past that range throws haxe.io.Eof, and getBytes takes what was written so far.
function main():Int {
	var output = new BytesOutput();
	output.writeInt32(0x12345678);
	output.writeDouble(-2.25);
	output.writeString("é✓");
	if (output.length != 17)
		return 1;
	var bytes = output.getBytes();
	if (bytes.length != 17 || bytes.get(0) != 0x78 || bytes.get(3) != 0x12)
		return 2;
	// Writing on leaves the bytes already taken as they were.
	output.writeByte(1);
	if (bytes.length != 17 || output.length != 18 || output.getBytes().get(17) != 1)
		return 3;
	var input = new BytesInput(bytes);
	var prefix = input.read(4);
	if (prefix.get(0) != 0x78 || input.position != 4)
		return 4;
	// read copies, while the input reads `bytes` itself.
	prefix.set(0, 0);
	if (bytes.get(0) != 0x78 || input.readDouble() != -2.25 || input.position != 12)
		return 5;
	if (input.readString(5) != "é✓" || input.position != bytes.length)
		return 6;
	try {
		input.readByte();
		return 7;
	} catch (_:Eof) {}
	try {
		input.readInt32();
		return 8;
	} catch (_:Eof) {}
	// A range of the bytes, read where it lies; a change to the bytes shows.
	var window = new BytesInput(bytes, 4, 8);
	bytes.set(4, 0);
	if (window.length != 8 || window.position != 4 || window.readByte() != 0)
		return 9;
	window.position = 12;
	try {
		window.readByte();
		return 10;
	} catch (_:Eof) {}
	var big = new BytesOutput();
	big.bigEndian = true;
	big.writeInt32(0x01020304);
	return big.getBytes().get(0) == 1 ? 42 : 11;
}
