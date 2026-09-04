package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.BytesInput;

typedef HlPersistentIdentity = {final moduleId:Bytes; final stableIds:Map<String, Int>; final typeState:Null<Bytes>;}

class HlRuntimeIdentity {
	public static inline final VERSION = 2;
	public static inline final RUNTIME_VERSION = 1;
	static var sequence = 1;

	public static function createModuleId():Bytes {
		var out = Bytes.alloc(16), now = Date.now().getTime(), id = sequence++;
		out.setInt32(0, Std.int(now));
		out.setInt32(4, Std.int(now / 4294967296.0));
		out.setInt32(8, Std.random(0x3FFFFFFF));
		out.setInt32(12, id);
		return out;
	}

	public static function encode(moduleId:Bytes, indices:Map<String, Int>, stableIds:Map<String, Int>):Bytes {
		if (moduleId.length != 16)
			throw "Module ID must contain 16 bytes";
		var names = [for (name in stableIds.keys()) if (indices.exists(name)) name];
		names.sort(Reflect.compare);
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HLI");
		out.writeByte(RUNTIME_VERSION);
		out.write(moduleId);
		out.writeInt32(names.length);
		for (name in names) {
			out.writeInt32(stableIds.get(name));
			out.writeInt32(indices.get(name));
		}
		return out.getBytes();
	}

	public static function encodePersistent(moduleId:Bytes, stableIds:Map<String, Int>, ?typeState:Bytes):Bytes {
		var names = [for (name in stableIds.keys()) name];
		names.sort(Reflect.compare);
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HCS");
		out.writeByte(VERSION);
		out.write(moduleId);
		out.writeInt32(names.length);
		for (name in names) {
			var bytes = Bytes.ofString(name);
			out.writeInt32(stableIds.get(name));
			out.writeInt32(bytes.length);
			out.write(bytes);
		}
		var types = typeState == null ? Bytes.alloc(0) : typeState;
		out.writeInt32(types.length);
		out.write(types);
		return out.getBytes();
	}

	public static function decodePersistent(bytes:Bytes):HlPersistentIdentity {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HCS")
				throw "Invalid compiler identity state";
			var version = input.readByte();
			if (version != 1 && version != VERSION)
				throw "Invalid compiler identity state";
			var moduleId = input.read(16),
				count = input.readInt32(),
				stableIds:Map<String, Int> = [];
			if (count < 0 || count > 0x100000)
				throw "Invalid compiler identity count";
			for (_ in 0...count) {
				var id = input.readInt32(), length = input.readInt32();
				if (id < 0 || length < 0 || length > 0x100000)
					throw "Invalid compiler identity entry";
				var name = input.readString(length);
				if (stableIds.exists(name))
					throw "Duplicate compiler identity name";
				stableIds.set(name, id);
			}
			var typeState:Null<Bytes> = null;
			if (version >= 2) {
				var typeLength = input.readInt32();
				if (typeLength < 0 || typeLength > 0x10000000 || typeLength > bytes.length - input.position)
					throw "Invalid compiler type identity state";
				typeState = input.read(typeLength);
			}
			if (input.position != bytes.length)
				throw "Trailing compiler identity data";
			return {moduleId: moduleId, stableIds: stableIds, typeState: typeState};
		} catch (error:haxe.io.Eof) {
			throw "Truncated compiler identity state";
		}
	}
}
