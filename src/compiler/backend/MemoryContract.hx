package compiler.backend;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import sys.io.File;

typedef MemoryContract = {
	final name:String;
	final version:Int;
	final addressModel:String;
	final pageSize:Int;
	final hostBase:Int;
	final hostLimit:Int;
	final guestBase:Int;
	final guestLimit:Int;
	final memorySize:Int;
}

/** Loads and serializes the versioned host/guest linear-memory ABI. */
class MemoryContractCodec {
	public static inline final MAGIC = "HMC";
	public static inline final SECTION_NAME = "haxeon.memory.contract";
	public static inline final CURRENT_VERSION:Int = 1;

	public static function load(path:String):MemoryContract {
		var parsed:Dynamic;
		try {
			parsed = haxe.Json.parse(File.getContent(path));
		} catch (error:Dynamic) {
			throw 'Invalid Wasm memory contract "$path": $error';
		}
		var result:MemoryContract = {
			name: requiredString(parsed, "name"),
			version: requiredInt(parsed, "version"),
			addressModel: requiredString(parsed, "address_model"),
			pageSize: requiredInt(parsed, "page_size"),
			hostBase: requiredInt(parsed, "host_base"),
			hostLimit: requiredInt(parsed, "host_limit"),
			guestBase: requiredInt(parsed, "guest_base"),
			guestLimit: requiredInt(parsed, "guest_limit"),
			memorySize: requiredInt(parsed, "memory_size")
		};
		validate(result);
		return result;
	}

	public static function validate(contract:MemoryContract):Void {
		if (contract.name != "nativekit-haxeon-linear-memory")
			throw 'Unsupported Wasm memory contract name "${contract.name}"';
		if (contract.version != CURRENT_VERSION)
			throw 'Unsupported Wasm memory contract version ${contract.version}';
		if (contract.addressModel != "wasm32")
			throw 'Unsupported Wasm memory address model "${contract.addressModel}"';
		if (contract.pageSize != 65536)
			throw 'Wasm memory contract page size must be 65536, got ${contract.pageSize}';
		if (contract.hostBase != 0 || contract.hostBase % 8 != 0 || contract.hostLimit % 8 != 0 ||
			contract.guestBase % 8 != 0 || contract.guestLimit % 8 != 0)
			throw "Wasm memory contract boundaries must be non-negative 8-byte aligned values";
		if (contract.hostBase >= contract.hostLimit || contract.hostLimit != contract.guestBase ||
			contract.guestBase >= contract.guestLimit || contract.guestLimit != contract.memorySize)
			throw "Wasm memory contract partitions are not contiguous and ordered";
		if (contract.hostLimit % contract.pageSize != 0 || contract.guestBase % contract.pageSize != 0 ||
			contract.guestLimit % contract.pageSize != 0)
			throw "Wasm memory contract boundaries must be Wasm-page aligned";
	}

	/** Binary payload embedded in the guest Wasm custom section. */
	public static function encode(contract:MemoryContract):Bytes {
		validate(contract);
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString(MAGIC);
		output.writeByte(contract.version);
		output.writeInt32(contract.pageSize);
		output.writeInt32(contract.hostBase);
		output.writeInt32(contract.hostLimit);
		output.writeInt32(contract.guestBase);
		output.writeInt32(contract.guestLimit);
		output.writeInt32(contract.memorySize);
		return output.getBytes();
	}

	static function requiredString(value:Dynamic, field:String):String {
		var result:Dynamic = value == null ? null : Reflect.field(value, field);
		if (result == null || !Std.isOfType(result, String) || result.length == 0)
			throw 'Wasm memory contract field "$field" must be a non-empty string';
		return result;
	}

	static function requiredInt(value:Dynamic, field:String):Int {
		var raw:Dynamic = value == null ? null : Reflect.field(value, field);
		if (raw == null)
			throw 'Wasm memory contract field "$field" is required';
		var result = Std.int(raw);
		if (result < 0 || raw != result)
			throw 'Wasm memory contract field "$field" must be a non-negative integer';
		return result;
	}
}
