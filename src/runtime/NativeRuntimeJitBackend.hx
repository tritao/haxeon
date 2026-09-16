package runtime;

/** Current HashLink-backed implementation of the Haxe JIT backend seam. */
final class NativeRuntimeJitBackend implements RuntimeJitBackend {
	public function new() {}

	public inline function applyPatch(module:RuntimeModuleHandle, bytes:hl.Bytes, length:Int):RuntimeStatus
		return RuntimeJit.patch(module, bytes, length);

	public inline function retainedCodeAllocationCount(module:RuntimeModuleHandle):Int
		return RuntimeJit.allocation_count(module);

	public inline function patchCount(module:RuntimeModuleHandle):Int
		return RuntimeJit.patch_jit_count(module);

	public inline function location(module:RuntimeModuleHandle, index:Int):hl.Bytes
		return RuntimeJit.jit_location(module, index);

	public inline function debugRegionCount(module:RuntimeModuleHandle):Int
		return RuntimeJit.debug_region_count(module);

	public inline function retiredCodeAllocationCount(module:RuntimeModuleHandle):Int
		return RuntimeJit.retired_allocation_count(module);

	public inline function injectPatchFailure(module:RuntimeModuleHandle, stage:Int):Void
		RuntimeJit.set_patch_failure_stage(module, stage);
}
