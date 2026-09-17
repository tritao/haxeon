package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlCode;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlFunction;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchDebug;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchInput;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchPools;
import runtime.hashlink.HashLinkTypeBindings.NativeHlModuleContext;
import runtime.hashlink.HashLinkTypeBindings.NativeHlType;

/** Small native boundary for handing Haxe-owned type metadata to HashLink. */
@:hlNative("haxeon_runtime")
class HlTypeBridge {
	public static function native_pointer_size():Int
		return 0;

	/** Publish one object prototype through HashLink's executable-pointer machinery. */
	public static function native_metadata_publish_object_prototype(type:RawPtr<NativeHlType>):Void {}

	public static function native_module_context_dispose(context:RawPtr<NativeHlModuleContext>):Void {}

	/** Allocate the native HashLink module wrapper for an arena-owned code record. */
	public static function native_metadata_module_alloc(code:RawPtr<NativeModuleHlCode>):RawPtr<UInt8>
		return RawPtr.nullPtr();

	/** Initialize the native JIT/module machinery for an arena-owned code record. */
	public static function native_metadata_module_init(module:RawPtr<UInt8>, flags:Int):Bool
		return false;

	/** Materialize one Haxe-owned constant through HashLink's GC-sensitive kernel. */
	public static function native_metadata_module_initialize_constant(module:RawPtr<UInt8>, index:Int):Bool
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
	public static function native_runtime_module_load_code(code:RawPtr<NativeModuleHlCode>, bytes:haxe.io.Bytes, length:Int, identity:haxe.io.Bytes,
		identityLength:Int):hl.Abstract<"realtime_module">
		return null;

	/** Load a legacy HLB/HLI pair through HashLink's native decoder. */
	public static function native_runtime_module_load_bytes(bytes:haxe.io.Bytes, identity:haxe.io.Bytes):hl.Abstract<"realtime_module">
		return null;

	/** Load a runtime wrapper from Haxe-owned code and decoded identity tables. The HLB payload is debugger-only and optional. */
	public static function native_runtime_module_load_code_manifest(code:RawPtr<NativeModuleHlCode>, bytes:haxe.io.Bytes, length:Int, moduleId:haxe.io.Bytes,
		revision:Int, stableIds:RawPtr<Int32>, slots:RawPtr<Int32>, identityCount:Int, initializerSlot:Int):hl.Abstract<"realtime_module">
		return null;

	/** Materialize one Haxe-owned constant through an external runtime wrapper. */
	public static function native_runtime_module_initialize_constant(module:hl.Abstract<"realtime_module">, index:Int):Bool
		return false;

	/** Retire an externally loaded runtime wrapper when no managed borrowers remain. */
	public static function native_runtime_module_unload(module:hl.Abstract<"realtime_module">):Bool
		return false;

	/** Retire an externally loaded runtime wrapper and preserve its native status code. */
	public static function native_runtime_module_dispose(module:hl.Abstract<"realtime_module">):Int
		return -1;

	/** Invoke a stable zero-argument i32 function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_i32(module:hl.Abstract<"realtime_module">, stableId:Int):Int
		return 0;

	/** Invoke a Haxe-resolved dispatch slot with an i32 result. */
	public static function native_runtime_module_call_i32_slot(module:hl.Abstract<"realtime_module">, slot:Int):Int
		return 0;

	/** Invoke a stable zero-argument void function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_void(module:hl.Abstract<"realtime_module">, stableId:Int):Void {}

	/** Invoke a Haxe-resolved dispatch slot with no result. */
	public static function native_runtime_module_call_void_slot(module:hl.Abstract<"realtime_module">, slot:Int):Void {}

	/** Invoke a stable zero-argument bytes-returning function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_bytes(module:hl.Abstract<"realtime_module">, stableId:Int):hl.Bytes
		return null;

	/** Invoke a Haxe-resolved dispatch slot returning bytes. */
	public static function native_runtime_module_call_bytes_slot(module:hl.Abstract<"realtime_module">, slot:Int):hl.Bytes
		return null;

	/** Invoke a stable bytes-argument function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_bytes1(module:hl.Abstract<"realtime_module">, stableId:Int, argument:hl.Bytes):Void {}

	/** Invoke a Haxe-resolved dispatch slot with a bytes argument. */
	public static function native_runtime_module_call_bytes1_slot(module:hl.Abstract<"realtime_module">, slot:Int, argument:hl.Bytes):Void {}

	/** Retain the closure returned by a stable function in an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_closure(module:hl.Abstract<"realtime_module">, stableId:Int):Dynamic
		return null;

	/** Retain the closure returned by a Haxe-resolved dispatch slot. */
	public static function native_runtime_module_call_closure_slot(module:hl.Abstract<"realtime_module">, slot:Int):Dynamic
		return null;

	/** Invoke one retained closure through its externally loaded runtime wrapper. */
	public static function native_runtime_module_call_closure_i32(module:hl.Abstract<"realtime_module">, closure:Dynamic):Int
		return 0;

	/** Retain the object returned by a stable function in an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_object(module:hl.Abstract<"realtime_module">, stableId:Int):Dynamic
		return null;

	/** Retain the object returned by a Haxe-resolved dispatch slot. */
	public static function native_runtime_module_call_object_slot(module:hl.Abstract<"realtime_module">, slot:Int):Dynamic
		return null;

	/** Invoke a stable object-argument function through an externally loaded runtime wrapper. */
	public static function native_runtime_module_call_i32_object(module:hl.Abstract<"realtime_module">, stableId:Int, argument:Dynamic):Int
		return 0;

	/** Invoke a Haxe-resolved dispatch slot with an object argument. */
	public static function native_runtime_module_call_i32_object_slot(module:hl.Abstract<"realtime_module">, slot:Int, argument:Dynamic):Int
		return 0;

	/** Recheck one stable call shape against the live native dispatch table. */
	public static function native_runtime_module_validate_call(module:hl.Abstract<"realtime_module">, stableId:Int, shape:Int):Int
		return -1;

	/** Recheck one Haxe-resolved dispatch slot against the live native table. */
	public static function native_runtime_module_validate_call_slot(module:hl.Abstract<"realtime_module">, slot:Int, shape:Int):Int
		return -1;

	/** Read the number of live managed allocations attributed to an external wrapper. */
	public static function native_runtime_module_live_allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	/** Read the number of native roots owned by an external runtime wrapper. */
	public static function native_runtime_module_native_root_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	/** Read the optional raw HLB payload size retained for legacy debugger MAP support. */
	public static function native_runtime_module_debug_hlb_size(module:hl.Abstract<"realtime_module">):Int
		return -1;

	/** Write the four-field retirement snapshot of an external runtime wrapper. */
	public static function native_runtime_module_retirement_status(module:hl.Abstract<"realtime_module">, out:hl.Bytes):Void {}

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
	public static function native_runtime_module_patch_code_haxe_metadata(module:hl.Abstract<"realtime_module">, input:RawPtr<NativeModuleHlPatchInput>, typeCount:Int,
		functions:RawPtr<NativeModuleHlFunction>, functionCount:Int, pools:RawPtr<NativeModuleHlPatchPools>, debug:RawPtr<NativeModuleHlPatchDebug>, status:hl.Bytes):hl.Abstract<"realtime_jit_code">
		return null;

	/** Release one Haxe-owned external reference to a published code allocation. */
	public static function native_runtime_module_release_code(code:hl.Abstract<"realtime_jit_code">):Bool
		return false;

	/** Read the immutable revision carried by one retained external code allocation. */
	public static function native_runtime_module_code_revision(code:hl.Abstract<"realtime_jit_code">):Int
	return -1;

	/** Read the number of native code allocations retained by an external wrapper. */
	public static function native_runtime_module_allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	/** Read the number of JIT-compiled patch functions published by an external wrapper. */
	public static function native_runtime_module_patch_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	/** Resolve one stable function's current native source location. */
	public static function native_runtime_module_jit_location(module:hl.Abstract<"realtime_module">, index:Int):hl.Bytes
		return null;

	/** Resolve one Haxe-selected dispatch slot to its current native source location. */
	public static function native_runtime_module_jit_location_slot(module:hl.Abstract<"realtime_module">, slot:Int):hl.Bytes
		return null;

	/** Read the number of debug regions retained by an external wrapper. */
	public static function native_runtime_module_debug_region_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	/** Read the number of detached native code allocations awaiting reclamation. */
	public static function native_runtime_module_retired_allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

}
