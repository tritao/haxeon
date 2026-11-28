// Haxe's Bytes.ofString with an encoding, and Haxe's streams with one, as Haxe's HashLink Bytes has them: RawNative is the
// string's UTF-16 code units, little-endian. Bytes methods take std.bytes.Encoding in Haxeon, so they are left out here
// (stdlib/UPSTREAM.md), as are ofHex's checks and readString.
import haxe.io.Bytes;
import haxe.io.Encoding;

class Main {
	static function main() {
		var text = "hé€😀z";
		var raw = Bytes.ofString(text, RawNative);
		Sys.println(raw.length + " " + raw.toHex());
		var utf8 = Bytes.ofString(text, UTF8);
		var encoding:Null<Encoding> = null;
		Sys.println(utf8.length + " " + utf8.toHex() + " " + utf8.getString(1, 5) + " "
			+ Bytes.ofString(text, encoding).toHex());
		Sys.println(Bytes.ofHex("00ff10Ab").toHex() + " " + Bytes.ofHex("").length);
		var buffer = new haxe.io.BytesBuffer();
		buffer.addString("é");
		var output = new haxe.io.BytesOutput();
		output.writeString("€", RawNative);
		Sys.println(buffer.getBytes().toHex() + " " + output.getBytes().toHex());
		var input = new haxe.io.BytesInput(raw);
		Sys.println(input.readString(4, RawNative) + " " + input.readString(2, RawNative));
	}
}
