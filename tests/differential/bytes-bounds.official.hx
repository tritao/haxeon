// Bytes outside its range as Haxe's HashLink Bytes has it: getters read 0, and writers, `sub` and `getString` throw,
// catchably, without changing the bytes. What they throw differs (haxe.io.Error.OutsideBounds in Haxe; stdlib/UPSTREAM.md).
import haxe.io.Bytes;

class Main {
	static function rejects(name:String, action:() -> Void):Void {
		try {
			action();
			Sys.println(name + " accepted");
		} catch (error:Dynamic) {
			Sys.println(name + " rejected");
		}
	}

	static function main() {
		var bytes = Bytes.alloc(8);
		for (index in 0...8)
			bytes.set(index, index + 1);
		Sys.println([
			bytes.get(-1),
			bytes.get(8),
			bytes.get(0x7FFFFFFF),
			bytes.getInt32(5),
			bytes.getInt32(8),
			bytes.getInt32(-4)
		]);
		Sys.println([bytes.getFloat(5), bytes.getDouble(1), bytes.getDouble(-8)]);
		rejects("set -1", () -> bytes.set(-1, 0));
		rejects("set 8", () -> bytes.set(8, 0));
		rejects("setInt32", () -> bytes.setInt32(5, 0));
		rejects("setFloat", () -> bytes.setFloat(5, 0));
		rejects("setDouble", () -> bytes.setDouble(1, 0));
		rejects("blit destination", () -> bytes.blit(4, bytes, 0, 5));
		rejects("blit source", () -> bytes.blit(0, bytes, 4, 5));
		rejects("blit negative", () -> bytes.blit(0, bytes, 0, -1));
		rejects("blit huge", () -> bytes.blit(1, bytes, 0, 0x7FFFFFFF));
		rejects("sub", () -> bytes.sub(4, 5));
		rejects("sub negative", () -> bytes.sub(-1, 2));
		rejects("getString", () -> bytes.getString(4, 5));
		rejects("getString negative", () -> bytes.getString(0, -1));
		rejects("blit empty", () -> bytes.blit(8, bytes, 0, 0));
		Sys.println(bytes.toHex());
		bytes.set(0, 0x141);
		Sys.println(bytes.get(0) + " " + bytes.sub(8, 0).length + " " + bytes.getString(0, 1));
	}
}
