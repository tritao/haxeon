package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;

/** Owns one runtime wrapper initialized from Haxe-built HashLink metadata. */
class HlRuntimeModule {
	public final metadata:HlMetadataGeneration;
	final lease:HlMetadataLease;
	var module:RawPtr<UInt8>;

	public function new(metadata:HlMetadataGeneration, bytes:Bytes, identity:Bytes) {
		if (metadata == null || bytes == null || identity == null)
			throw "HashLink runtime module requires metadata, HLB bytes, and HLI bytes";
		this.metadata = metadata;
		lease = metadata.acquire();
		module = RawPtr.nullPtr();
		try {
			module = HlTypeBridge.native_runtime_module_load_code(metadata.snapshot().nativeCode, bytes, bytes.length, identity, identity.length);
			if (module.isNull())
				throw "HashLink external runtime module initialization failed";
		} catch (error:Dynamic) {
			lease.release();
			throw error;
		}
	}

	/** Whether the native runtime wrapper remains initialized. */
	public inline function isLoaded():Bool
		return !module.isNull();

	/** Invoke a stable zero-argument i32 function. */
	public function callI32(stableId:Int):Int {
		if (!isLoaded())
			throw "HashLink external runtime module is no longer loaded";
		return HlTypeBridge.native_runtime_module_call_i32(module, stableId);
	}

	/** Invoke a stable zero-argument void function. */
	public function callVoid(stableId:Int):Void {
		if (!isLoaded())
			throw "HashLink external runtime module is no longer loaded";
		HlTypeBridge.native_runtime_module_call_void(module, stableId);
	}

	/** Retire the wrapper, preserving the metadata lease if native borrowers block it. */
	public function unload():Bool {
		if (!isLoaded())
			return true;
		if (!HlTypeBridge.native_runtime_module_unload(module))
			return false;
		module = RawPtr.nullPtr();
		lease.release();
		return true;
	}
}
