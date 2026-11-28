// Bytes.fill and the 16-bit and Int64 accessors as Haxe's HashLink Bytes has them: a range outside the bytes throws before
// anything is written, a fill stores each value's low byte, and an out-of-range read is 0. What a write throws differs
// (haxe.io.Error.OutsideBounds in Haxe; stdlib/UPSTREAM.md).
import haxe.io.Bytes;

class Main {
	static function dump(bytes:Bytes):String
		return [for (index in 0...bytes.length) Std.string(bytes.get(index))].join(",");

	static function rejects(action:() -> Void):String {
		try {
			action();
			return "accepted";
		} catch (error:Dynamic) {
			return "rejected";
		}
	}

	static function main() {
		var bytes = Bytes.alloc(10);
		bytes.fill(0, 10, 7);
		Sys.println(dump(bytes));
		bytes.fill(2, 3, 0x1FF);
		Sys.println(dump(bytes));
		bytes.fill(10, 0, 1);
		bytes.fill(0, 0, 1);
		Sys.println(dump(bytes));
		Sys.println(rejects(() -> bytes.fill(-1, 2, 1)));
		Sys.println(rejects(() -> bytes.fill(0, -1, 1)));
		Sys.println(rejects(() -> bytes.fill(8, 3, 1)));
		Sys.println(rejects(() -> bytes.fill(11, 0, 1)));
		Sys.println(rejects(() -> bytes.fill(1, 0x7FFFFFFF, 1)));
		Sys.println(dump(bytes));

		bytes.setUInt16(0, 0x12345);
		Sys.println(bytes.getUInt16(0) + " " + bytes.get(0) + " " + bytes.get(1));
		bytes.setUInt16(8, 0xFFFF);
		Sys.println(bytes.getUInt16(8) + " " + bytes.getUInt16(9) + " " + bytes.getUInt16(-2));
		Sys.println(rejects(() -> bytes.setUInt16(9, 1)));

		bytes.setInt64(1, haxe.Int64.make(0x01020304, 0x05060708));
		var read = bytes.getInt64(1);
		Sys.println(read.high + " " + read.low + " " + dump(bytes));
		var outside = bytes.getInt64(3);
		Sys.println(outside.high + " " + outside.low);
		Sys.println(rejects(() -> bytes.setInt64(3, haxe.Int64.ofInt(1))));
		bytes.setInt64(2, haxe.Int64.ofInt(-1));
		Sys.println(dump(bytes));
	}
}
