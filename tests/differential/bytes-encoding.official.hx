// Bytes.ofString and getString with an encoding, ofHex and readString as Haxe's HashLink Bytes has them: RawNative is the
// string's UTF-16 code units, little-endian, and decoding it stops at a zero unit.
import haxe.io.Bytes;
import haxe.io.Encoding;

class Main {
	static function main() {
		var text = "hé€😀z";
		var raw = Bytes.ofString(text, RawNative);
		Sys.println(raw.length + " " + raw.toHex());
		Sys.println(raw.getString(0, raw.length, RawNative));
		Sys.println(raw.getString(2, 4, RawNative) + " " + raw.getString(4, 6, Encoding.RawNative));
		Sys.println(raw.getString(0, 5, RawNative));
		var stopped = Bytes.alloc(6);
		stopped.set(0, 0x41);
		stopped.set(4, 0x42);
		Sys.println(stopped.getString(0, 6, RawNative));
		var utf8 = Bytes.ofString(text, UTF8);
		var encoding:Null<Encoding> = null;
		Sys.println(utf8.length + " " + utf8.toHex() + " " + utf8.getString(1, 5, UTF8) + " " + utf8.getString(0, 3,
			encoding));
		Sys.println(utf8.readString(0, 3));
		Sys.println(Bytes.ofHex("00ff10Ab").toHex() + " " + Bytes.ofHex("").length + " " + Bytes.ofHex("zz").toHex());
		try {
			Bytes.ofHex("abc");
		} catch (error:String) {
			Sys.println(error);
		}
		var buffer = new haxe.io.BytesBuffer();
		buffer.addString("é", RawNative);
		buffer.addString("é");
		var output = new haxe.io.BytesOutput();
		output.writeString("€", RawNative);
		Sys.println(buffer.getBytes().toHex() + " " + output.getBytes().toHex());
		var input = new haxe.io.BytesInput(raw);
		Sys.println(input.readString(4, RawNative) + " " + input.readString(2, RawNative));
		try {
			raw.getString(0, 100, RawNative);
		} catch (error:haxe.io.Error) {
			Sys.println(error);
		}
	}
}
