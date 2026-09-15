package runtime.hashlink;

import runtime.memory.RawPtr;

/** Owns one initialized native HashLink module and its metadata lease. */
class HlNativeModule {
	public final metadata:HlMetadataGeneration;
	public final publication:HlMetadataPublication;
	final lease:HlMetadataLease;
	var module:RawPtr<UInt8>;

	public function new(metadata:HlMetadataGeneration, ?flags:Int = 0) {
		if (metadata == null)
			throw "HashLink native module requires metadata";
		this.metadata = metadata;
		lease = metadata.acquire();
		publication = lease.publication;
		module = RawPtr.nullPtr();
		try {
			module = HlTypeBridge.native_metadata_module_alloc(publication.nativeCode);
			if (module.isNull())
				throw "HashLink native module allocation failed";
			if (!HlTypeBridge.native_metadata_module_init(module, flags)) {
				HlTypeBridge.native_metadata_module_free_shutdown(module);
				module = RawPtr.nullPtr();
				throw "HashLink native module initialization failed";
			}
		} catch (error:Dynamic) {
			if (!module.isNull())
				HlTypeBridge.native_metadata_module_free_shutdown(module);
			lease.release();
			throw error;
		}
	}

	/** Whether the native module remains initialized and owned by this wrapper. */
	public inline function isLoaded():Bool
		return !module.isNull();

	/** Native handle for kernel operations that are not policy-owned yet. */
	public function pointer():RawPtr<UInt8> {
		if (!isLoaded())
			throw "HashLink native module is no longer loaded";
		return module;
	}

	/** Invoke a zero-argument Haxe-owned function through HashLink's JIT. */
	public function callI32(functionIndex:Int):Int {
		if (!isLoaded())
			throw "HashLink native module is no longer loaded";
		return HlTypeBridge.native_metadata_module_call_i32(module, functionIndex);
	}

	/** Try to retire the module; a failed retirement keeps its lease and handle alive. */
	public function unload():Bool {
		if (!isLoaded())
			return true;
		if (!HlTypeBridge.native_metadata_module_unload(module))
			return false;
		module = RawPtr.nullPtr();
		lease.release();
		return true;
	}

	/** Require native retirement and report a live-allocation failure to the caller. */
	public function close():Void {
		if (!unload())
			throw "HashLink native module could not be unloaded";
	}
}
