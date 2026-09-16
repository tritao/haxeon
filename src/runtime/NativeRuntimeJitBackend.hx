package runtime;

#if haxeon
import compiler.hl.HlNativeMetadataBuilder;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataTypeAppend;
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

	public inline function applyPatch(module:RuntimeModuleHandle, transaction:RuntimePatchTransaction
			#if haxeon, metadata:HlMetadataGeneration #end):RuntimeJitPublication {
		#if haxeon
		if (metadata == null)
			return new RuntimeJitPublication(RuntimeStatus.BadArgument, null);
		var typeAppend:HlMetadataTypeAppend = null;
		try {
			typeAppend = HlNativeMetadataBuilder.preparePatchTypes(transaction.owner.model, metadata, transaction.model);
			var patchPools = HlNativeMetadataBuilder.preparePatchPools(transaction.owner.model, metadata, transaction.model);
			var patchFunctions = HlNativeMetadataBuilder.preparePatchFunctions(metadata, transaction.model, transaction.owner.identity);
			var patchDebug = HlNativeMetadataBuilder.preparePatchDebug(metadata, transaction.model);
			var patchResolution = HlNativeMetadataBuilder.preparePatchResolution(metadata, transaction.model, transaction.owner.identity);
			var patchInput = HlNativeMetadataBuilder.preparePatchInput(metadata, transaction.model, patchDebug, patchResolution);
			var publication = haxeBackend.patchCodeWithHaxeMetadata(cast module, patchInput, transaction.model.types.length, patchFunctions, patchPools,
				patchDebug);
			if (publication.status != RuntimeStatus.Ok) {
				typeAppend.rollback();
				if (publication.code != null)
					haxeBackend.releaseCode(publication.code);
				return new RuntimeJitPublication(cast publication.status, null);
			}
			try {
				typeAppend.commit();
			} catch (error:Dynamic) {
				if (publication.code != null)
					haxeBackend.releaseCode(publication.code);
				typeAppend.rollback();
				throw error;
			}
			return new RuntimeJitPublication(cast publication.status, cast publication.code);
		} catch (error:Dynamic) {
			if (typeAppend != null)
				typeAppend.rollback();
			throw error;
		}
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
