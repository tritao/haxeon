// Bytes.fill and the 16-bit and Int64 accessors, on every target.
import haxe.io.Bytes;

function rejects(action:() -> Void):Bool {
	try {
		action();
		return false;
	} catch (error:haxe.Exception) {
		return error.message == "std.bytes.Bytes: the position or range is outside the bytes";
	}
}

function main():Int {
	var bytes = Bytes.alloc(6);
	bytes.fill(0, 6, 7);
	bytes.fill(1, 2, 0x1FF);
	if (bytes.get(0) != 7 || bytes.get(1) != 255 || bytes.get(2) != 255 || bytes.get(3) != 7 || bytes.get(5) != 7)
		return 1;
	bytes.fill(6, 0, 1);
	if (!rejects(() -> bytes.fill(-1, 1, 0)) || !rejects(() -> bytes.fill(0, -1, 0))
		|| !rejects(() -> bytes.fill(4, 3, 0))
		|| !rejects(() -> bytes.fill(1, 0x7FFFFFFF, 0)) || bytes.get(4) != 7)
		return 2;
	bytes.setUInt16(0, 0x12345);
	if (bytes.getUInt16(0) != 0x2345 || bytes.get(0) != 0x45 || bytes.getUInt16(5) != 0
		|| !rejects(() -> bytes.setUInt16(5, 1)))
		return 3;
	var wide = Bytes.alloc(9);
	wide.setInt64(1, haxe.Int64.make(0x01020304, 0x05060708));
	var read = wide.getInt64(1);
	if (read.high != 0x01020304 || read.low != 0x05060708 || wide.get(1) != 8 || wide.get(8) != 1)
		return 4;
	var outside = wide.getInt64(2);
	if (outside.high != 0 || outside.low != 0 || !rejects(() -> wide.setInt64(2, haxe.Int64.ofInt(1))))
		return 5;
	return 42;
}
