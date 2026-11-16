// Bytes.toHex gives the bytes as lowercase hexadecimal, as Haxe's does, on every target.
function main():Int {
	var bytes = haxe.io.Bytes.alloc(3);
	bytes.set(0, 0);
	bytes.set(1, 0xAB);
	bytes.set(2, 0x7F);
	if (bytes.toHex() != "00ab7f" || haxe.io.Bytes.ofString("Hi").toHex() != "4869"
		|| haxe.io.Bytes.alloc(0).toHex() != "")
		return 1;
	return 42;
}
