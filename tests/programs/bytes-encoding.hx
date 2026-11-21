// Bytes.ofString and getString with an encoding, ofHex and readString, as Haxe's HashLink Bytes has them on every target:
// RawNative is the string's UTF-16 code units, little-endian, and decoding it stops at a zero unit.
import haxe.io.Bytes;
import haxe.io.Encoding;

function main():Int {
	var text = "hé€😀z";
	var raw = Bytes.ofString(text, RawNative);
	if (raw.length != 12 || raw.toHex() != "6800e900ac203dd800de7a00")
		return 1;
	if (raw.getString(0, raw.length, RawNative) != text || raw.getString(2, 4, RawNative) != "é€"
		|| raw.getString(4, 6, Encoding.RawNative) != "€😀")
		return 2;
	// An odd last byte is a unit's low byte.
	if (raw.getString(0, 5, RawNative) != "hé¬")
		return 3;
	var stopped = Bytes.alloc(6);
	stopped.set(0, 0x41);
	stopped.set(4, 0x42);
	if (stopped.getString(0, 6, RawNative) != "A")
		return 4;
	var utf8 = Bytes.ofString(text);
	var encoding:Null<Encoding> = null;
	if (utf8.length != 11 || Bytes.ofString(text, UTF8).toHex() != utf8.toHex()
		|| utf8.getString(1, 5, UTF8) != "é€" || utf8.getString(0, 3, encoding) != "hé")
		return 5;
	if (utf8.readString(0, 3) != "hé")
		return 6;
	if (Bytes.ofHex("00ff10Ab").toHex() != "00ff10ab" || Bytes.ofHex("").length != 0)
		return 7;
	try {
		Bytes.ofHex("abc");
		return 8;
	} catch (error:String) {
		if (error != "Not a hex string (odd number of digits)")
			return 9;
	}
	var buffer = new haxe.io.BytesBuffer();
	buffer.addString("é", RawNative);
	buffer.addString("é");
	var output = new haxe.io.BytesOutput();
	output.writeString("€", RawNative);
	if (buffer.getBytes().toHex() != "e900c3a9" || output.getBytes().toHex() != "ac20")
		return 10;
	var input = new haxe.io.BytesInput(raw);
	if (input.readString(4, RawNative) != "hé" || input.readString(2, RawNative) != "€")
		return 11;
	return 42;
}
