package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;
import runtime.hashlink.HlRuntimeJitBackend.HlRuntimeModuleHandle;

/**
	Haxe-owned interface for the bootstrap-sensitive runtime-module boundary.
	The kernel owns only native handle creation, calls, failure injection, and
	retirement; module policy and executable-code policy stay in Haxe.
*/
interface HlRuntimeModuleKernel {
	function loadCodeManifest(code:RawPtr<HlNativeCode>, bytes:Bytes, moduleId:Bytes, revision:Int, stableIds:RawPtr<Int32>,
		slots:RawPtr<Int32>, identityCount:Int, initializerSlot:Int):HlRuntimeModuleHandle;
	function callI32(module:HlRuntimeModuleHandle, stableId:Int):Int;
	function callVoid(module:HlRuntimeModuleHandle, stableId:Int):Void;
	function setPatchFailureStage(module:HlRuntimeModuleHandle, stage:Int):Void;
	function unload(module:HlRuntimeModuleHandle):Bool;
}

/** Current HashLink implementation of the narrow runtime-module kernel. */
class NativeHlRuntimeModuleKernel implements HlRuntimeModuleKernel {
	public function new() {}

	public inline function loadCodeManifest(code:RawPtr<HlNativeCode>, bytes:Bytes, moduleId:Bytes, revision:Int, stableIds:RawPtr<Int32>,
		slots:RawPtr<Int32>, identityCount:Int, initializerSlot:Int):HlRuntimeModuleHandle
		return HlTypeBridge.native_runtime_module_load_code_manifest(code, bytes, bytes.length, moduleId, revision, stableIds, slots, identityCount,
			initializerSlot);

	public inline function callI32(module:HlRuntimeModuleHandle, stableId:Int):Int
		return HlTypeBridge.native_runtime_module_call_i32(module, stableId);

	public inline function callVoid(module:HlRuntimeModuleHandle, stableId:Int):Void
		HlTypeBridge.native_runtime_module_call_void(module, stableId);

	public inline function setPatchFailureStage(module:HlRuntimeModuleHandle, stage:Int):Void
		HlTypeBridge.native_runtime_module_set_patch_failure_stage(module, stage);

	public inline function unload(module:HlRuntimeModuleHandle):Bool
		return HlTypeBridge.native_runtime_module_unload(module);
}
