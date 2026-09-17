package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlObjectPrototypeKernel;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlCode;
import runtime.hashlink.HashLinkTypeBindings.NativeHlModuleContext;
import runtime.hashlink.HashLinkTypeBindings.NativeHlType;

/**
	Haxe-owned interface for the native metadata-module boundary.
	The kernel owns only native module handles, GC-sensitive materialization,
	dispatch publication, and retirement; metadata construction and lifecycle
	policy stay in Haxe.
*/
interface HlMetadataModuleKernel extends HlObjectPrototypeKernel {
	function allocate(code:RawPtr<NativeModuleHlCode>):RawPtr<UInt8>;
	function initialize(module:RawPtr<UInt8>, flags:Int):Bool;
	function publishObjectPrototype(type:RawPtr<NativeHlType>):Void;
	function disposeContext(context:RawPtr<NativeHlModuleContext>):Void;
	function initializeConstant(module:RawPtr<UInt8>, index:Int):Bool;
	function unload(module:RawPtr<UInt8>):Bool;
	function patchGeneration(target:RawPtr<UInt8>, generation:RawPtr<UInt8>):Bool;
	function patchSlots(target:RawPtr<UInt8>, generation:RawPtr<UInt8>, indices:RawPtr<Int32>, count:Int):Bool;
	function freeShutdown(module:RawPtr<UInt8>):Void;
	function callI32(module:RawPtr<UInt8>, functionIndex:Int):Int;
}

/** Current HashLink implementation of the narrow metadata-module kernel. */
class NativeHlMetadataModuleKernel implements HlMetadataModuleKernel {
	public function new() {}

	public inline function allocate(code:RawPtr<NativeModuleHlCode>):RawPtr<UInt8>
		return HlTypeBridge.native_metadata_module_alloc(code);

	public inline function initialize(module:RawPtr<UInt8>, flags:Int):Bool
		return HlTypeBridge.native_metadata_module_init(module, flags);

	public inline function publishObjectPrototype(type:RawPtr<NativeHlType>):Void
		HlTypeBridge.native_metadata_publish_object_prototype(type);

	public inline function disposeContext(context:RawPtr<NativeHlModuleContext>):Void
		HlTypeBridge.native_module_context_dispose(context);

	public inline function initializeConstant(module:RawPtr<UInt8>, index:Int):Bool
		return HlTypeBridge.native_metadata_module_initialize_constant(module, index);

	public inline function unload(module:RawPtr<UInt8>):Bool
		return HlTypeBridge.native_metadata_module_unload(module);

	public inline function patchGeneration(target:RawPtr<UInt8>, generation:RawPtr<UInt8>):Bool
		return HlTypeBridge.native_metadata_module_patch_generation(target, generation);

	public inline function patchSlots(target:RawPtr<UInt8>, generation:RawPtr<UInt8>, indices:RawPtr<Int32>, count:Int):Bool
		return HlTypeBridge.native_metadata_module_patch_slots(target, generation, indices, count);

	public inline function freeShutdown(module:RawPtr<UInt8>):Void
		HlTypeBridge.native_metadata_module_free_shutdown(module);

	public inline function callI32(module:RawPtr<UInt8>, functionIndex:Int):Int
		return HlTypeBridge.native_metadata_module_call_i32(module, functionIndex);
}
