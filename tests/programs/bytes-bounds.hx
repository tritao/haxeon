// Bytes outside its range, on every target: getters read 0, and writers, `sub` and `getString` throw, catchable, without
// changing the bytes.
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
	var bytes = Bytes.alloc(8);
	for (index in 0...8)
		bytes.set(index, index + 1);
	if (bytes.get(-1) != 0 || bytes.get(8) != 0 || bytes.get(0x7FFFFFFF) != 0 || bytes.get(7) != 8)
		return 1;
	if (bytes.getInt32(5) != 0 || bytes.getInt32(-1) != 0 || bytes.getInt32(4) != 0x08070605)
		return 2;
	if (bytes.getFloat(5) != 0 || bytes.getDouble(1) != 0 || bytes.getDouble(-8) != 0)
		return 3;
	if (!rejects(() -> bytes.set(-1, 0)) || !rejects(() -> bytes.set(8, 0)) || !rejects(() -> bytes.setInt32(5, 0))
		|| !rejects(() -> bytes.setFloat(5, 0)) || !rejects(() -> bytes.setDouble(1, 0)))
		return 4;
	if (!rejects(() -> bytes.blit(4, bytes, 0, 5)) || !rejects(() -> bytes.blit(0, bytes, 4, 5))
		|| !rejects(() -> bytes.blit(0, bytes, 0, -1)) || !rejects(() -> bytes.blit(-1, bytes, 0, 1))
		|| !rejects(() -> bytes.blit(1, bytes, 0, 0x7FFFFFFF)))
		return 5;
	if (!rejects(() -> bytes.sub(4, 5)) || !rejects(() -> bytes.sub(-1, 2)) || !rejects(() -> bytes.sub(0, -1))
		|| !rejects(() -> bytes.getString(4, 5)) || !rejects(() -> bytes.getString(0, -1)))
		return 6;
	for (index in 0...8)
		if (bytes.get(index) != index + 1)
			return 7;
	bytes.set(0, 0x141);
	bytes.blit(8, bytes, 0, 0);
	if (bytes.get(0) != 0x41 || bytes.sub(8, 0).length != 0 || bytes.getString(0, 1) != "A")
		return 8;
	return 42;
}
