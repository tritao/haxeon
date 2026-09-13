import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

function main():Int {
	var output = new BytesOutput();
	output.writeInt32(0x12345678);
	output.writeDouble(-2.25);
	output.writeString("é✓");
	var bytes = output.getBytes();
	if (bytes.length != 17)
		return 1;
	var input = new BytesInput(bytes);
	var prefix = input.read(4);
	if (prefix.get(0) != 0x12 || prefix.get(3) != 0x78)
		return 2;
	prefix.set(0, 0);
	bytes.set(4, 0);
	if (bytes.get(0) != 0x12 || input.readDouble() != -2.25 || input.position != 12)
		return 3;
	if (input.readString(5) != "é✓" || input.position != bytes.length)
		return 4;
	var snapshot = output.getBytes();
	output.writeByte(90);
	return snapshot.length == 17 && output.getBytes().length == 18 ? 42 : 5;
}
