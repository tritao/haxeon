package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;
import runtime.hashlink.HlObjectPrototypeKernel;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlCode;
import runtime.hashlink.HlRuntimeJitBackend.HlRuntimeModuleHandle;

/**
	Haxe-owned interface for the bootstrap-sensitive runtime-module boundary.
	The kernel owns only native handle creation, calls, failure injection, and
	retirement; module policy and executable-code policy stay in Haxe.
*/
interface HlRuntimeModuleKernel extends HlObjectPrototypeKernel {
	/** Load Haxe-owned execution metadata with an optional debugger payload. */
	function loadCodeManifest(code:RawPtr<NativeModuleHlCode>, moduleId:Bytes, revision:Int, dispatch:HlRuntimeDispatchTable, ?debugBytes:Bytes):HlRuntimeModuleHandle;
	function initializeConstant(module:HlRuntimeModuleHandle, index:Int):Bool;
	function callI32Slot(module:HlRuntimeModuleHandle, slot:Int):Int;
	function callVoidSlot(module:HlRuntimeModuleHandle, slot:Int):Void;
	function callBytesSlot(module:HlRuntimeModuleHandle, slot:Int):hl.Bytes;
	function callBytes1Slot(module:HlRuntimeModuleHandle, slot:Int, argument:hl.Bytes):Void;
	function callClosureSlot(module:HlRuntimeModuleHandle, slot:Int):Dynamic;
	function callClosureI32(module:HlRuntimeModuleHandle, closure:Dynamic):Int;
	function callObjectSlot(module:HlRuntimeModuleHandle, slot:Int):Dynamic;
	function callI32ObjectSlot(module:HlRuntimeModuleHandle, slot:Int, argument:Dynamic):Int;
	function validateCallSlot(module:HlRuntimeModuleHandle, slot:Int, shape:Int):Int;
	function liveAllocationCount(module:HlRuntimeModuleHandle):Int;
	function nativeRootCount(module:HlRuntimeModuleHandle):Int;
	function debugHlbSize(module:HlRuntimeModuleHandle):Int;
	function retirementStatus(module:HlRuntimeModuleHandle, out:hl.Bytes):Void;
	function dispose(module:HlRuntimeModuleHandle):Int;
	function setPatchFailureStage(module:HlRuntimeModuleHandle, stage:Int):Void;
	function unload(module:HlRuntimeModuleHandle):Bool;
}

/** Current HashLink implementation of the narrow runtime-module kernel. */
class NativeHlRuntimeModuleKernel implements HlRuntimeModuleKernel {
	public function new() {}

	public inline function loadCodeManifest(code:RawPtr<NativeModuleHlCode>, moduleId:Bytes, revision:Int, dispatch:HlRuntimeDispatchTable,
		?debugBytes:Bytes):HlRuntimeModuleHandle {
		var debugLength = debugBytes == null ? 0 : debugBytes.length;
		return HlTypeBridge.native_runtime_module_load_code_manifest(code, debugBytes, debugLength, moduleId, revision, dispatch.stableIds, dispatch.slots,
			dispatch.count, dispatch.initializerSlot);
	}

	public inline function publishObjectPrototype(type:RawPtr<HlType>):Void
		HlTypeBridge.native_metadata_publish_object_prototype(type);

	public inline function initializeConstant(module:HlRuntimeModuleHandle, index:Int):Bool
		return HlTypeBridge.native_runtime_module_initialize_constant(module, index);

	public inline function callI32Slot(module:HlRuntimeModuleHandle, slot:Int):Int
		return HlTypeBridge.native_runtime_module_call_i32_slot(module, slot);

	public inline function callVoidSlot(module:HlRuntimeModuleHandle, slot:Int):Void
		HlTypeBridge.native_runtime_module_call_void_slot(module, slot);

	public inline function callBytesSlot(module:HlRuntimeModuleHandle, slot:Int):hl.Bytes
		return HlTypeBridge.native_runtime_module_call_bytes_slot(module, slot);

	public inline function callBytes1Slot(module:HlRuntimeModuleHandle, slot:Int, argument:hl.Bytes):Void
		HlTypeBridge.native_runtime_module_call_bytes1_slot(module, slot, argument);

	public inline function callClosureSlot(module:HlRuntimeModuleHandle, slot:Int):Dynamic
		return HlTypeBridge.native_runtime_module_call_closure_slot(module, slot);

	public inline function callClosureI32(module:HlRuntimeModuleHandle, closure:Dynamic):Int
		return HlTypeBridge.native_runtime_module_call_closure_i32(module, closure);

	public inline function callObjectSlot(module:HlRuntimeModuleHandle, slot:Int):Dynamic
		return HlTypeBridge.native_runtime_module_call_object_slot(module, slot);

	public inline function callI32ObjectSlot(module:HlRuntimeModuleHandle, slot:Int, argument:Dynamic):Int
		return HlTypeBridge.native_runtime_module_call_i32_object_slot(module, slot, argument);

	public inline function validateCallSlot(module:HlRuntimeModuleHandle, slot:Int, shape:Int):Int
		return HlTypeBridge.native_runtime_module_validate_call_slot(module, slot, shape);

	public inline function liveAllocationCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_live_allocation_count(module);

	public inline function nativeRootCount(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_native_root_count(module);

	public inline function debugHlbSize(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_debug_hlb_size(module);

	public inline function retirementStatus(module:HlRuntimeModuleHandle, out:hl.Bytes):Void
		HlTypeBridge.native_runtime_module_retirement_status(module, out);

	public inline function dispose(module:HlRuntimeModuleHandle):Int
		return HlTypeBridge.native_runtime_module_dispose(module);

	public inline function setPatchFailureStage(module:HlRuntimeModuleHandle, stage:Int):Void
		HlTypeBridge.native_runtime_module_set_patch_failure_stage(module, stage);

	public inline function unload(module:HlRuntimeModuleHandle):Bool
		return HlTypeBridge.native_runtime_module_unload(module);

}
