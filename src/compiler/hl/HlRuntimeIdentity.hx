package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.BytesInput;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.RuntimeAbiCodec;

/** Compiler identity and acknowledged publication baseline restored across sessions. */
typedef HlPersistentIdentity = {
	final moduleId:Bytes;
	final stableIds:Map<String, Int>;
	final typeState:Null<Bytes>;
	final publishedAbi:Null<RuntimeAbiDescriptor>;
	final publicationTracking:Bool;
	final acknowledgedRevision:Int;
	final acknowledgedAbi:Null<RuntimeAbiDescriptor>;
	final assemblerState:Null<Bytes>;
}

/** Encodes runtime manifests and persistent compiler identity state. */
class HlRuntimeIdentity {
	public static inline final VERSION = 5;
	public static inline final RUNTIME_VERSION = 2;
	static var sequence = 1;

	public static function createModuleId():Bytes {
		var out = Bytes.alloc(16), now = Date.now().getTime(), id = sequence++;
		out.setInt32(0, Std.int(now));
		out.setInt32(4, Std.int(now / 4294967296.0));
		out.setInt32(8, Std.random(0x3FFFFFFF));
		out.setInt32(12, id);
		return out;
	}

	public static function encode(moduleId:Bytes, revision:Int, indices:Map<String, Int>, stableIds:Map<String, Int>):Bytes {
		if (moduleId.length != 16)
			throw "Module ID must contain 16 bytes";
		if (revision < 0)
			throw "Runtime revision cannot be negative";
		var names = [for (name in stableIds.keys()) if (indices.exists(name)) name];
		names.sort(Reflect.compare);
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HLI");
		out.writeByte(RUNTIME_VERSION);
		out.write(moduleId);
		out.writeInt32(revision);
		out.writeInt32(names.length);
		for (name in names) {
			out.writeInt32(stableIds.get(name));
			out.writeInt32(indices.get(name));
		}
		return out.getBytes();
	}

	public static function encodePersistent(moduleId:Bytes, stableIds:Map<String, Int>, ?typeState:Bytes, ?publishedAbi:RuntimeAbiDescriptor,
			?publicationTracking:Bool = false, ?acknowledgedRevision:Int = 0, ?acknowledgedAbi:RuntimeAbiDescriptor, ?assemblerState:Bytes):Bytes {
		if (moduleId.length != 16)
			throw "Module ID must contain 16 bytes";
		if (acknowledgedRevision < 0
			|| (!publicationTracking && (acknowledgedRevision != 0 || acknowledgedAbi != null))
			|| (acknowledgedRevision > 0 && (acknowledgedAbi == null || assemblerState == null))
			|| (acknowledgedRevision == 0 && assemblerState != null))
			throw "Invalid acknowledged publication state";
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
		var abi = publishedAbi == null ? Bytes.alloc(0) : RuntimeAbiCodec.encode(publishedAbi);
		out.writeInt32(abi.length);
		out.write(abi);
		out.writeByte(publicationTracking ? 1 : 0);
		out.writeInt32(acknowledgedRevision);
		var acknowledged = acknowledgedAbi == null ? Bytes.alloc(0) : RuntimeAbiCodec.encode(acknowledgedAbi);
		out.writeInt32(acknowledged.length);
		out.write(acknowledged);
		var backend = assemblerState == null ? Bytes.alloc(0) : assemblerState;
		out.writeInt32(backend.length);
		out.write(backend);
		return out.getBytes();
	}

	public static function decodePersistent(bytes:Bytes):HlPersistentIdentity {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HCS")
				throw "Invalid compiler identity state";
			var version = input.readByte();
			if (version != VERSION)
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
			var typeLength = input.readInt32();
			if (typeLength < 0 || typeLength > 0x10000000 || typeLength > bytes.length - input.position)
				throw "Invalid compiler type identity state";
			var typeState:Null<Bytes> = input.read(typeLength);
			var publishedAbi:Null<RuntimeAbiDescriptor> = null;
			var abiLength = input.readInt32();
			if (abiLength < 0 || abiLength > 0x10000000 || abiLength > bytes.length - input.position)
				throw "Invalid published ABI state";
			if (abiLength > 0)
				publishedAbi = RuntimeAbiCodec.decode(input.read(abiLength));
			var trackingByte = input.readByte();
			if (trackingByte != 0 && trackingByte != 1)
				throw "Invalid publication tracking state";
			var publicationTracking = trackingByte == 1,
				acknowledgedRevision = input.readInt32(),
				acknowledgedLength = input.readInt32();
			if (acknowledgedRevision < 0
				|| acknowledgedLength < 0
				|| acknowledgedLength > 0x10000000
				|| acknowledgedLength > bytes.length - input.position)
				throw "Invalid acknowledged publication state";
			var acknowledgedAbi:Null<RuntimeAbiDescriptor> = acknowledgedLength == 0 ? null : RuntimeAbiCodec.decode(input.read(acknowledgedLength));
			if ((!publicationTracking && (acknowledgedRevision != 0 || acknowledgedAbi != null))
				|| (acknowledgedRevision > 0 && acknowledgedAbi == null))
				throw "Invalid acknowledged publication state";
			var assemblerLength = input.readInt32();
			if (assemblerLength < 0 || assemblerLength > 0x10000000 || assemblerLength > bytes.length - input.position)
				throw "Invalid assembler baseline state";
			var assemblerState:Null<Bytes> = assemblerLength == 0 ? null : input.read(assemblerLength);
			if ((acknowledgedRevision > 0 && assemblerState == null) || (acknowledgedRevision == 0 && assemblerState != null))
				throw "Invalid acknowledged assembler baseline";
			if (input.position != bytes.length)
				throw "Trailing compiler identity data";
			return {
				moduleId: moduleId,
				stableIds: stableIds,
				typeState: typeState,
				publishedAbi: publishedAbi,
				publicationTracking: publicationTracking,
				acknowledgedRevision: acknowledgedRevision,
				acknowledgedAbi: acknowledgedAbi,
				assemblerState: assemblerState
			};
		} catch (error:haxe.io.Eof) {
			throw "Truncated compiler identity state";
		}
	}
}
