package runtime;

/** Current HashLink-backed implementation of the Haxe JIT backend seam. */
class NativeRuntimeJitBackend implements RuntimeJitBackend {
	public function new() {}

	public inline function applyPatch(module:RuntimeModuleHandle, transaction:RuntimePatchTransaction):RuntimeJitPublication {
		#if haxeon
		var status = haxe.io.Bytes.alloc(4),
			code = RuntimeJit.patch_code(module, cast transaction.patchSet.bytes.getData(), transaction.patchSet.bytes.length, cast status.getData()),
			result:RuntimeStatus = status.getInt32(0);
		#else
		var status = new hl.Bytes(4),
			code = RuntimeJit.patch_code(module, transaction.patchSet.bytes.getData(), transaction.patchSet.bytes.length, status),
			result:RuntimeStatus = status.getI32(0);
		#end
		if (result != RuntimeStatus.Ok && code != null)
			RuntimeJit.release_code(code);
		return new RuntimeJitPublication(result, code);
	}

	public inline function releaseCode(code:RuntimeJitCodeHandle):Bool
		return RuntimeJit.release_code(code);

	public inline function codeRevision(code:RuntimeJitCodeHandle):Int
		return RuntimeJit.code_revision(code);

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
