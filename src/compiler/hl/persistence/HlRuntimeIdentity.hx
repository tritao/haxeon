package compiler.hl.persistence;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.RuntimeAbiCodec;
import compiler.core.InternalError;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Compiler identity and acknowledged publication baseline restored across sessions. */
typedef HlPersistentIdentity = {
	final moduleId:Bytes;
	final typeState:Null<Bytes>;
	final publishedAbi:Null<RuntimeAbiDescriptor>;
	final publicationTracking:Bool;
	final acknowledgedRevision:Int;
	final acknowledgedAbi:Null<RuntimeAbiDescriptor>;
	final assemblerState:Null<Bytes>;
	final specializationState:Null<Bytes>;
}

/** Encodes runtime manifests and persistent compiler identity state. */
class HlRuntimeIdentity {
	/** Version 11: the loader gives functions their stable ids, so the state keeps none.
	 * Version 10: live modules are module sections, whose slots and stable ids the loader gives.
	 * Version 9: virtual types retain their nominal interface identities.
	 * Version 8: objects carry an unnamed field per implemented interface to cache its virtual, so earlier type tables cannot be patched.
	 * Version 7: Strings are HashLink String objects.
	 */
	public static inline final VERSION = 11;

	/**
	 * HLI 4: the module id, the revision and the name of the module's initializer. The loader gives every function its stable id
	 * (`hl_runtime_module_function_id` finds one by name), so the identity lists none.
	 */
	public static inline final RUNTIME_VERSION = 4;

	/** The function a module runs when it loads, when it has one. */
	public static inline final INITIALIZER = "__init";

	@:processWide("makes each identity this process mints distinct; a process-wide counter by design")
	static var sequence = 1;

	public static function createModuleId():Bytes {
		var out = Bytes.alloc(16), now = Date.now().getTime(), id = sequence++;
		out.setInt32(0, Std.int(now));
		out.setInt32(4, Std.int(now / 4294967296.0));
		out.setInt32(8, Std.random(0x3FFFFFFF));
		out.setInt32(12, id);
		return out;
	}

	/** The HLI of revision `revision` of module `moduleId`; `initialized` says whether the module has an initializer to run. */
	public static function encode(moduleId:Bytes, revision:Int, initialized:Bool):Bytes {
		if (moduleId.length != 16)
			throw new InternalError("Module ID must contain 16 bytes");
		if (revision < 0)
			throw new InternalError("Runtime revision cannot be negative");
		var initializer = Bytes.ofString(initialized ? INITIALIZER : "");
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HLI");
		out.writeByte(RUNTIME_VERSION);
		out.write(moduleId);
		out.writeInt32(revision);
		out.writeInt32(initializer.length);
		out.write(initializer);
		return out.getBytes();
	}

	public static function encodePersistent(moduleId:Bytes, ?typeState:Bytes,
			?publishedAbi:RuntimeAbiDescriptor,
			?publicationTracking:Bool = false, ?acknowledgedRevision:Int = 0, ?acknowledgedAbi:RuntimeAbiDescriptor,
			?assemblerState:Bytes,
			?specializationState:Bytes):Bytes {
		if (moduleId.length != 16)
			throw new InternalError("Module ID must contain 16 bytes");
		if (acknowledgedRevision < 0
			|| (!publicationTracking && (acknowledgedRevision != 0 || acknowledgedAbi != null))
			|| (acknowledgedRevision > 0 && (acknowledgedAbi == null || assemblerState == null))
			|| (acknowledgedRevision == 0 && assemblerState != null))
			throw new InternalError("Invalid acknowledged publication state");
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HCS");
		out.writeByte(VERSION);
		out.write(moduleId);
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
		var specializations = specializationState == null ? Bytes.alloc(0) : specializationState;
		out.writeInt32(specializations.length);
		out.write(specializations);
		return out.getBytes();
	}

	public static function decodePersistent(bytes:Bytes):HlPersistentIdentity {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HCS")
				throw new InternalError("Invalid compiler identity state");
			var version = input.readByte();
			if (version != VERSION)
				throw new InternalError("Invalid compiler identity state");
			var moduleId = input.read(16);
			var typeLength = input.readInt32();
			if (typeLength < 0 || typeLength > 0x10000000 || typeLength > bytes.length - input.position)
				throw new InternalError("Invalid compiler type identity state");
			var typeState:Null<Bytes> = input.read(typeLength);
			var publishedAbi:Null<RuntimeAbiDescriptor> = null;
			var abiLength = input.readInt32();
			if (abiLength < 0 || abiLength > 0x10000000 || abiLength > bytes.length - input.position)
				throw new InternalError("Invalid published ABI state");
			if (abiLength > 0)
				publishedAbi = RuntimeAbiCodec.decode(input.read(abiLength));
			var trackingByte = input.readByte();
			if (trackingByte != 0 && trackingByte != 1)
				throw new InternalError("Invalid publication tracking state");
			var publicationTracking = trackingByte == 1,
				acknowledgedRevision = input.readInt32(),
				acknowledgedLength = input.readInt32();
			if (acknowledgedRevision < 0
				|| acknowledgedLength < 0
				|| acknowledgedLength > 0x10000000
				|| acknowledgedLength > bytes.length - input.position)
				throw new InternalError("Invalid acknowledged publication state");
			var acknowledgedAbi:Null<RuntimeAbiDescriptor> = acknowledgedLength == 0
				? null : RuntimeAbiCodec.decode(input.read(acknowledgedLength));
			if ((!publicationTracking && (acknowledgedRevision != 0 || acknowledgedAbi != null))
				|| (acknowledgedRevision > 0 && acknowledgedAbi == null))
				throw new InternalError("Invalid acknowledged publication state");
			var assemblerLength = input.readInt32();
			if (assemblerLength < 0 || assemblerLength > 0x10000000 || assemblerLength > bytes.length - input.position)
				throw new InternalError("Invalid assembler baseline state");
			var assemblerState:Null<Bytes> = assemblerLength == 0 ? null : input.read(assemblerLength);
			if ((acknowledgedRevision > 0 && assemblerState == null)
				|| (acknowledgedRevision == 0 && assemblerState != null))
				throw new InternalError("Invalid acknowledged assembler baseline");
			var specializationLength = input.readInt32();
			if (specializationLength < 0 || specializationLength > 0x10000000
				|| specializationLength > bytes.length - input.position)
				throw new InternalError("Invalid generic specialization state");
			var specializationState:Null<Bytes> = specializationLength == 0 ? null : input.read(specializationLength);
			if (input.position != bytes.length)
				throw new InternalError("Trailing compiler identity data");
			return {
				moduleId: moduleId,
				typeState: typeState,
				publishedAbi: publishedAbi,
				publicationTracking: publicationTracking,
				acknowledgedRevision: acknowledgedRevision,
				acknowledgedAbi: acknowledgedAbi,
				assemblerState: assemblerState,
				specializationState: specializationState
			};
		} catch (error:haxe.io.Eof) {
			throw new InternalError("Truncated compiler identity state");
		}
	}
}
