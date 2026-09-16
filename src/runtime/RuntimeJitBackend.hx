package runtime;

#if haxeon
import runtime.hashlink.HlMetadataGeneration;
#end

/**
	Haxe-owned seam for executable-code publication and JIT diagnostics.

	The backend receives an opaque module handle, but does not own patch policy,
	function generations, or module lifetime. Those remain in the runtime facade.
 */
interface RuntimeJitBackend {
	function applyPatch(module:RuntimeModuleHandle, transaction:RuntimePatchTransaction #if haxeon, metadata:HlMetadataGeneration #end):RuntimeJitPublication;
	function releaseCode(code:RuntimeJitCodeHandle):Bool;
	function codeRevision(code:RuntimeJitCodeHandle):Int;
	function retainedCodeAllocationCount(module:RuntimeModuleHandle):Int;
	function patchCount(module:RuntimeModuleHandle):Int;
	function location(module:RuntimeModuleHandle, index:Int):hl.Bytes;
	function debugRegionCount(module:RuntimeModuleHandle):Int;
	function retiredCodeAllocationCount(module:RuntimeModuleHandle):Int;
	function injectPatchFailure(module:RuntimeModuleHandle, stage:Int):Void;
}
