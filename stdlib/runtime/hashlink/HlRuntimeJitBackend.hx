package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;

/** Opaque native module handle consumed by the Haxe-owned JIT seam. */
typedef HlRuntimeModuleHandle = hl.Abstract<"realtime_module">;

/** Opaque native code allocation retained by one Haxe-owned patch generation. */
typedef HlRuntimeJitCodeHandle = hl.Abstract<"realtime_jit_code">;

/**
	Haxe-owned interface for the executable-code portion of the HashLink bridge.
	The backend does not decide patch compatibility, function versions, or
	module lifetime; it only publishes and releases native code allocations.
*/
interface HlRuntimeJitBackend {
	function patch(module:HlRuntimeModuleHandle, bytes:Bytes):Int;
	function patchCode(module:HlRuntimeModuleHandle, bytes:Bytes):HlRuntimePatchPublication;
	function patchCodeWithHaxeTypes(module:HlRuntimeModuleHandle, bytes:Bytes, typeCount:Int):HlRuntimePatchPublication;
	function patchCodeWithHaxeMetadata(module:HlRuntimeModuleHandle, input:RawPtr<HlRuntimePatchInput>, typeCount:Int,
		functions:HlRuntimePatchFunctions, pools:RawPtr<HlPatchPools>, debug:RawPtr<HlRuntimePatchDebug>):HlRuntimePatchPublication;
	function releaseCode(code:Null<HlRuntimeJitCodeHandle>):Bool;
	function codeRevision(code:Null<HlRuntimeJitCodeHandle>):Int;
	function allocationCount(module:HlRuntimeModuleHandle):Int;
	function patchCount(module:HlRuntimeModuleHandle):Int;
	function locationSlot(module:HlRuntimeModuleHandle, slot:Int):hl.Bytes;
	function debugRegionCount(module:HlRuntimeModuleHandle):Int;
	function retiredAllocationCount(module:HlRuntimeModuleHandle):Int;
}

/** Current HashLink implementation of the narrow Haxe-built JIT seam. */
class NativeHlRuntimeJitBackend implements HlRuntimeJitBackend {
	public function new() {}

	public inline function patch(module:HlRuntimeModuleHandle, bytes:Bytes):Int
		return HlTypeBridge.native_runtime_module_patch(module, bytes, bytes.length);

	public inline function patchCode(module:HlRuntimeModuleHandle, bytes:Bytes):HlRuntimePatchPublication {
		var status = Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code(module, bytes, bytes.length, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	public inline function patchCodeWithHaxeTypes(module:HlRuntimeModuleHandle, bytes:Bytes, typeCount:Int):HlRuntimePatchPublication {
		var status = Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code_haxe_types(module, bytes, bytes.length, typeCount, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	public inline function patchCodeWithHaxeMetadata(module:HlRuntimeModuleHandle, input:RawPtr<HlRuntimePatchInput>, typeCount:Int,
		functions:HlRuntimePatchFunctions, pools:RawPtr<HlPatchPools>, debug:RawPtr<HlRuntimePatchDebug>):HlRuntimePatchPublication {
		var status = Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code_haxe_metadata(module, input, typeCount, functions.pointer, functions.count,
				pools, debug, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	public inline function releaseCode(code:Null<HlRuntimeJitCodeHandle>):Bool
		return code == null || HlTypeBridge.native_runtime_module_release_code(code);

	public inline function codeRevision(code:Null<HlRuntimeJitCodeHandle>):Int
		return code == null ? -1 : HlTypeBridge.native_runtime_module_code_revision(code);

	public inline function allocationCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_allocation_count(module);

	public inline function patchCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_patch_count(module);

	public inline function locationSlot(module:HlRuntimeModuleHandle, slot:Int):hl.Bytes
		return HlTypeBridge.native_runtime_module_jit_location_slot(module, slot);

	public inline function debugRegionCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_debug_region_count(module);

	public inline function retiredAllocationCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_retired_allocation_count(module);
}
