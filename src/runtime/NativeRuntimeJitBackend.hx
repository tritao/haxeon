package runtime;

#if haxeon
import runtime.hashlink.HlRuntimeJitBackend;
import runtime.hashlink.HlRuntimeJitBackend.NativeHlRuntimeJitBackend;
#end

/** Current HashLink-backed implementation of the Haxe JIT backend seam. */
class NativeRuntimeJitBackend implements RuntimeJitBackend {
	#if haxeon
	final haxeBackend:HlRuntimeJitBackend;

	public function new(?haxeBackend:HlRuntimeJitBackend) {
		this.haxeBackend = haxeBackend == null ? new NativeHlRuntimeJitBackend() : haxeBackend;
	}
	#else
	public function new() {}
	#end

	public inline function applyPatch(module:RuntimeModuleHandle, transaction:RuntimePatchTransaction):RuntimeJitPublication {
		#if haxeon
		return HaxeRuntimePatchPublisher.publish(haxeBackend, module, transaction);
		#else
		var status = new hl.Bytes(4),
			code = RuntimeJit.patch_code(module, transaction.patchSet.bytes.getData(), transaction.patchSet.bytes.length, status),
			result:RuntimeStatus = status.getI32(0);
		if (result != RuntimeStatus.Ok && code != null)
			RuntimeJit.release_code(code);
		return new RuntimeJitPublication(result, code);
		#end
	}

	public inline function releaseCode(code:RuntimeJitCodeHandle):Bool
		#if haxeon
		return haxeBackend.releaseCode(cast code);
		#else
		return RuntimeJit.release_code(code);
		#end

	public inline function codeRevision(code:RuntimeJitCodeHandle):Int
		#if haxeon
		return haxeBackend.codeRevision(cast code);
		#else
		return RuntimeJit.code_revision(code);
		#end

	public inline function retainedCodeAllocationCount(module:RuntimeModuleHandle):Int
		#if haxeon
		return haxeBackend.allocationCount(cast module);
		#else
		return RuntimeJit.allocation_count(module);
		#end

	public inline function patchCount(module:RuntimeModuleHandle):Int
		#if haxeon
		return haxeBackend.patchCount(cast module);
		#else
		return RuntimeJit.patch_jit_count(module);
		#end

	public inline function location(module:RuntimeModuleHandle, index:Int):hl.Bytes
		#if haxeon
		return haxeBackend.location(cast module, index);
		#else
		return RuntimeJit.jit_location(module, index);
		#end

	public inline function debugRegionCount(module:RuntimeModuleHandle):Int
		#if haxeon
		return haxeBackend.debugRegionCount(cast module);
		#else
		return RuntimeJit.debug_region_count(module);
		#end

	public inline function retiredCodeAllocationCount(module:RuntimeModuleHandle):Int
		#if haxeon
		return haxeBackend.retiredAllocationCount(cast module);
		#else
		return RuntimeJit.retired_allocation_count(module);
		#end

	#if !haxeon
	public inline function injectPatchFailure(module:RuntimeModuleHandle, stage:Int):Void
		RuntimeJit.set_patch_failure_stage(module, stage);
	#end
}
