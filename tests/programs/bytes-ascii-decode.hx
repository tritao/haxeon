import haxe.io.Bytes;
import haxe.io.BytesInput;

class Main {
	public static function main():Int {
		for (length in [0, 1, 7, 15, 16, 17, 31, 32, 33, 60, 63, 64, 65, 127, 128, 129, 255, 1024]) {
			var bytes = Bytes.alloc(length + 2);
			bytes.set(length + 1, 128);
			var expected = new StringBuf();
			for (i in 0...length) {
				var code = 1 + i % 127;
				bytes.set(i + 1, code);
				expected.addChar(code);
			}
			var text = bytes.getString(1, length);
			if (text != expected.toString())
				return 1;
			var copy = Bytes.ofString(text);
			if (copy.length != length || copy.toString() != text)
				return 2;
			var input = new BytesInput(copy);
			if (input.readString(length) != text || input.position != length)
				return 3;
			if (length > 0) {
				bytes.set(1, 42);
				if (text.charCodeAt(0) != 1)
					return 4;
			}
		}
		for (text in ["é", "Ω", "✓", "中", "😀", "aé✓😀z"]) {
			var bytes = Bytes.ofString(text);
			if (bytes.toString() != text || bytes.getString(0, bytes.length) != text)
				return 5;
			var input = new BytesInput(bytes);
			if (input.readString(bytes.length) != text || input.position != bytes.length)
				return 6;
		}
		return 42;
	}
}
