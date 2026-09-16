package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;
import runtime.hashlink.HlPatchDebug.HlRuntimePatchDebug;

/** Owns one runtime wrapper initialized from Haxe-built HashLink metadata. */
class HlRuntimeModule {
	public final metadata:HlMetadataGeneration;
	final lease:HlMetadataLease;
	var module:Null<hl.Abstract<"realtime_module">>;

	public function new(metadata:HlMetadataGeneration, bytes:Bytes, moduleId:Bytes, revision:Int, stableIds:Array<Int>, slots:Array<Int>, initializerSlot:Int) {
		if (metadata == null || bytes == null || moduleId == null || moduleId.length != 16 || stableIds == null || slots == null
			|| stableIds.length != slots.length || revision < 0 || initializerSlot < -1)
			throw "HashLink runtime module requires metadata, HLB bytes, and a decoded HLI manifest";
		this.metadata = metadata;
		lease = metadata.acquire();
		module = null;
		try {
			var count = stableIds.length,
				stableIdStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count),
				slotStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count);
			for (index in 0...count) {
				if (stableIds[index] < 0 || slots[index] < 0)
					throw "HashLink runtime module manifest entries must be non-negative";
				stableIdStorage.offset(index).store(cast stableIds[index]);
				slotStorage.offset(index).store(cast slots[index]);
			}
			module = HlTypeBridge.native_runtime_module_load_code_manifest(metadata.snapshot().nativeCode, bytes, bytes.length, moduleId, revision,
				stableIdStorage, slotStorage, count, initializerSlot);
			if (module == null)
				throw "HashLink external runtime module initialization failed";
		} catch (error:Dynamic) {
			lease.release();
			throw error;
		}
	}

	/** Whether the native runtime wrapper remains initialized. */
	public inline function isLoaded():Bool
		return module != null;

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

	/** Apply an HLP transaction; policy validation belongs to the owning loader. */
	public function patch(bytes:Bytes):Int {
		if (!isLoaded() || bytes == null)
			throw "HashLink external runtime patch requires a loaded module and patch bytes";
		return HlTypeBridge.native_runtime_module_patch(module, bytes, bytes.length);
	}

	/** Apply a patch while retaining the published native code allocation. */
	public function patchCode(bytes:Bytes):HlRuntimePatchPublication {
		if (!isLoaded() || bytes == null)
			throw "HashLink external runtime patch requires a loaded module and patch bytes";
		return patchCodeInternal(bytes, -1);
	}

	/** Apply a patch while using Haxe-owned compatible appended type records. */
	public function patchCodeWithHaxeTypes(bytes:Bytes, typeCount:Int):HlRuntimePatchPublication {
		if (!isLoaded() || bytes == null || typeCount < 0)
			throw "HashLink external runtime patch requires a loaded module, patch bytes, and a non-negative type count";
		return patchCodeInternal(bytes, typeCount);
	}

	/** Apply a patch while using Haxe-owned type and function metadata. */
	public function patchCodeWithHaxeMetadata(bytes:Bytes, typeCount:Int, functions:HlRuntimePatchFunctions,
			pools:RawPtr<HlPatchPools>, debug:RawPtr<HlRuntimePatchDebug>):HlRuntimePatchPublication {
		if (!isLoaded() || bytes == null || typeCount < 0 || functions == null || pools.isNull() || debug.isNull())
			throw "HashLink external runtime patch requires a loaded module, patch bytes, type count, function metadata, scalar pools, and debug metadata";
		var status = haxe.io.Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code_haxe_metadata(module, bytes, bytes.length, typeCount, functions.pointer, functions.count,
				pools, debug, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	function patchCodeInternal(bytes:Bytes, typeCount:Int):HlRuntimePatchPublication {
		var status = haxe.io.Bytes.alloc(4),
			code = typeCount < 0 ? HlTypeBridge.native_runtime_module_patch_code(module, bytes, bytes.length, cast status.getData())
				: HlTypeBridge.native_runtime_module_patch_code_haxe_types(module, bytes, bytes.length, typeCount, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	/** Release one externally retained patch-code allocation. */
	public function releaseCode(code:Null<hl.Abstract<"realtime_jit_code">>):Bool
		return code == null || HlTypeBridge.native_runtime_module_release_code(code);

	/** Read the immutable revision carried by one retained patch-code allocation. */
	public function codeRevision(code:Null<hl.Abstract<"realtime_jit_code">>):Int
		return code == null ? -1 : HlTypeBridge.native_runtime_module_code_revision(code);

	/** Retire the wrapper, preserving the metadata lease if native borrowers block it. */
	public function unload():Bool {
		if (!isLoaded())
			return true;
		if (!HlTypeBridge.native_runtime_module_unload(module))
			return false;
		module = null;
		lease.release();
		return true;
	}
}
