package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlFunction;
import runtime.hashlink.HlPatchDebug.HlRuntimePatchDebug;
import runtime.hashlink.HlPatchInput.HlRuntimePatchInput;
import runtime.hashlink.HlPatchResolution.HlRuntimePatchResolution;

/** Small native boundary for handing Haxe-owned type metadata to HashLink. */
@:hlNative("haxeon_runtime")
class HlTypeBridge {
	public static function native_pointer_size():Int
		return 0;

	/** Publish one object prototype through HashLink's executable-pointer machinery. */
	public static function native_metadata_publish_object_prototype(type:RawPtr<HlType>):Void {}

	public static function native_module_context_dispose(context:RawPtr<HlModuleContext>):Void {}

	/** Allocate the native HashLink module wrapper for an arena-owned code record. */
	public static function native_metadata_module_alloc(code:RawPtr<HlNativeCode>):RawPtr<UInt8>
		return RawPtr.nullPtr();

	/** Initialize the native JIT/module machinery for an arena-owned code record. */
	public static function native_metadata_module_init(module:RawPtr<UInt8>, flags:Int):Bool
		return false;

	/** Retire and free an initialized native HashLink module. */
	public static function native_metadata_module_unload(module:RawPtr<UInt8>):Bool
		return false;

	/** Redirect a patchable module's function slots to an initialized generation. */
	public static function native_metadata_module_patch_generation(target:RawPtr<UInt8>, generation:RawPtr<UInt8>):Bool
		return false;

	/** Redirect an explicit set of compatible function slots to an initialized generation. */
	public static function native_metadata_module_patch_slots(target:RawPtr<UInt8>, generation:RawPtr<UInt8>, indices:RawPtr<Int32>, count:Int):Bool
		return false;

	/** Free a native module whose initialization failed before it entered the registry. */
	public static function native_metadata_module_free_shutdown(module:RawPtr<UInt8>):Void {}

	/** Invoke a zero-argument Haxe-owned function with an i32 result. */
	public static function native_metadata_module_call_i32(module:RawPtr<UInt8>, functionIndex:Int):Int
		return 0;

	/** Load a runtime wrapper from a Haxe-owned code record and external identity bytes. */
	public static function native_runtime_module_load_code(code:RawPtr<HlNativeCode>, bytes:haxe.io.Bytes, length:Int, identity:haxe.io.Bytes,
		identityLength:Int):hl.Abstract<"realtime_module">
		return null;

	/** Load a runtime wrapper from a Haxe-owned code record and decoded identity tables. */
	public static function native_runtime_module_load_code_manifest(code:RawPtr<HlNativeCode>, bytes:haxe.io.Bytes, length:Int, moduleId:haxe.io.Bytes,
		revision:Int, stableIds:RawPtr<Int32>, slots:RawPtr<Int32>, identityCount:Int, initializerSlot:Int):hl.Abstract<"realtime_module">
		return null;

	/** Retire an externally loaded runtime wrapper when no managed borrowers remain. */
	public static function native_runtime_module_unload(module:hl.Abstract<"realtime_module">):Bool
		return false;

	/** Invoke a stable zero-argument i32 function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_i32(module:hl.Abstract<"realtime_module">, stableId:Int):Int
		return 0;

	/** Invoke a stable zero-argument void function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_void(module:hl.Abstract<"realtime_module">, stableId:Int):Void {}

	/** Apply one HLP transaction to an externally loaded runtime wrapper. */
	public static function native_runtime_module_patch(module:hl.Abstract<"realtime_module">, bytes:haxe.io.Bytes, length:Int):Int
		return -1;

	/** Inject one native patch-staging failure for rollback tests. */
	public static function native_runtime_module_set_patch_failure_stage(module:hl.Abstract<"realtime_module">, stage:Int):Void {}

	/** Apply one HLP transaction and retain its published native code allocation. */
	public static function native_runtime_module_patch_code(module:hl.Abstract<"realtime_module">, bytes:haxe.io.Bytes, length:Int, status:hl.Bytes):hl.Abstract<"realtime_jit_code">
		return null;

	/** Apply one HLP transaction using Haxe-owned compatible appended type records. */
	public static function native_runtime_module_patch_code_haxe_types(module:hl.Abstract<"realtime_module">, bytes:haxe.io.Bytes, length:Int, typeCount:Int,
		status:hl.Bytes):hl.Abstract<"realtime_jit_code">
		return null;

	/** Apply one Haxe-decoded patch model using Haxe-owned metadata. */
	public static function native_runtime_module_patch_code_haxe_metadata(module:hl.Abstract<"realtime_module">, input:RawPtr<HlRuntimePatchInput>, typeCount:Int,
		functions:RawPtr<HlFunction>, functionCount:Int, pools:RawPtr<HlPatchPools>, debug:RawPtr<HlRuntimePatchDebug>, resolution:RawPtr<HlRuntimePatchResolution>,
		status:hl.Bytes):hl.Abstract<"realtime_jit_code">
		return null;

	/** Release one Haxe-owned external reference to a published code allocation. */
	public static function native_runtime_module_release_code(code:hl.Abstract<"realtime_jit_code">):Bool
		return false;

	/** Read the immutable revision carried by one retained external code allocation. */
	public static function native_runtime_module_code_revision(code:hl.Abstract<"realtime_jit_code">):Int
		return -1;

}
