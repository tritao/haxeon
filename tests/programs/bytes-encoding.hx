// Bytes.ofString and getString with an encoding, and ofHex, on every target: Utf16 is the string's UTF-16 code units,
// little-endian, and decoding it stops at a zero unit. Haxe's streams take Haxe's encodings, RawNative for Utf16.
import std.bytes.Bytes;
import std.bytes.Encoding;

function main():Int {
	var text = "hé€😀z";
	var raw = Bytes.ofString(text, Utf16);
	if (raw.length != 12 || raw.toHex() != "6800e900ac203dd800de7a00")
		return 1;
	if (raw.getString(0, raw.length, Utf16) != text || raw.getString(2, 4, Utf16) != "é€"
		|| raw.getString(4, 6, Encoding.Utf16) != "€😀")
		return 2;
	// An odd last byte is a unit's low byte.
	if (raw.getString(0, 5, Utf16) != "hé¬")
		return 3;
	var stopped = Bytes.alloc(6);
	stopped.set(0, 0x41);
	stopped.set(4, 0x42);
	if (stopped.getString(0, 6, Utf16) != "A")
		return 4;
	var utf8 = Bytes.ofString(text);
	if (utf8.length != 11 || Bytes.ofString(text, Utf8).toHex() != utf8.toHex() || utf8.getString(1, 5) != "é€"
		|| utf8.getString(0, 3, Utf8) != "hé")
		return 5;
	// Haxe's Bytes.ofString is the same bytes, RawNative for Utf16.
	if (haxe.io.Bytes.ofString(text, RawNative).compare(raw) != 0 || haxe.io.Bytes.ofString(text).compare(utf8) != 0)
		return 6;
	if (Bytes.ofHex("00ff10Ab").toHex() != "00ff10ab" || Bytes.ofHex("").length != 0)
		return 7;
	for (bad in ["abc", "zz", "0g"])
		try {
			Bytes.ofHex(bad);
			return 8;
		} catch (error:haxe.Exception) {
			if (error.message.indexOf("std.bytes.Bytes.ofHex") != 0)
				return 9;
		}
	var buffer = new std.bytes.BytesBuffer();
	buffer.addString("é", Utf16);
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
