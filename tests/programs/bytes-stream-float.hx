import haxe.io.BytesInput;
import haxe.io.BytesOutput;

// writeFloat stores a 32-bit IEEE float in either byte order, and readFloat returns it widened to Float.
function main():Int {
	var output = new BytesOutput();
	output.writeFloat(1.5);
	output.setBigEndian(false);
	output.writeFloat(-0.15625);
	output.writeFloat(0.1);
	var bytes = output.getBytes();
	if (bytes.length != 12)
		return 1;
	// 1.5 is 0x3FC00000, big-endian first; -0.15625 is 0xBE200000, little-endian.
	if (bytes.get(0) != 0x3F || bytes.get(1) != 0xC0 || bytes.get(3) != 0x00)
		return 2;
	if (bytes.get(4) != 0x00 || bytes.get(6) != 0x20 || bytes.get(7) != 0xBE)
		return 3;
	var input = new BytesInput(bytes);
	if (input.readFloat() != 1.5 || input.position != 4)
		return 4;
	input.setBigEndian(false);
	if (input.readFloat() != -0.15625)
		return 5;
	// 0.1 is not a float; it comes back as the nearest one, not as the double.
	var tenth = input.readFloat();
	if (tenth == 0.1 || Math.abs(tenth - 0.1) > 1e-8)
		return 6;
	return input.position == 12 ? 42 : 7;
}
