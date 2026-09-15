package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlFunction;

/** Small native boundary for handing Haxe-owned type metadata to HashLink. */
@:hlNative("haxeon_runtime")
class HlTypeBridge {
	public static function native_type_kind(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_size(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_pad_struct(type:RawPtr<HlType>, size:Int):Int
		return 0;

	public static function native_type_is_ptr(type:RawPtr<HlType>):Bool
		return false;

	public static function native_type_mark_size(size:Int):Int
		return 0;

	public static function native_pointer_size():Int
		return 0;

	public static function native_type_data_size(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_object_field_offset(type:RawPtr<HlType>, field:Int):Int
		return 0;

	public static function native_type_initialize_object(type:RawPtr<HlType>):Void {}

	public static function native_metadata_bind_function_descriptors(types:RawPtr<RawPtr<HlType>>, count:Int, functions:RawPtr<HlFunction>, functionCount:Int,
		context:RawPtr<HlModuleContext>):Void {}

	public static function native_metadata_bind_contiguous_function_descriptors(types:RawPtr<HlType>, count:Int, functions:RawPtr<HlFunction>, functionCount:Int,
		context:RawPtr<HlModuleContext>):Void {}

	public static function native_metadata_publish_prototypes(types:RawPtr<RawPtr<HlType>>, count:Int, context:RawPtr<HlModuleContext>):Void {}

	public static function native_metadata_publish_contiguous_prototypes(types:RawPtr<HlType>, count:Int, context:RawPtr<HlModuleContext>):Void {}

	public static function native_module_context_dispose(context:RawPtr<HlModuleContext>):Void {}

	/** Validate that a Haxe-owned function descriptor exposes native opcode storage. */
	public static function native_metadata_validate_function_code(descriptor:RawPtr<HlFunction>):Int
		return 0;

	public static function native_metadata_validate_debug_files(files:RawPtr<RawPtr<UInt8>>, count:Int):Int
		return 0;

	public static function native_metadata_validate_function_debug(descriptor:RawPtr<HlFunction>, debugFileCount:Int):Int
		return 0;

	/** Validate the Haxe-owned global type and value-slot tables as HashLink metadata. */
	public static function native_metadata_validate_global_types(types:RawPtr<RawPtr<HlType>>, count:Int,
		globals:RawPtr<RawPtr<UInt8>>):Int
		return 0;

	public static function native_metadata_validate_constants(constants:RawPtr<HlConstant>, count:Int, globalCount:Int):Int
		return 0;

	public static function native_metadata_validate_module_pools(ints:RawPtr<Int32>, intCount:Int, floats:RawPtr<Float>, floatCount:Int,
		strings:RawPtr<RawPtr<UInt8>>, stringLengths:RawPtr<Int32>, stringCount:Int, bytes:RawPtr<UInt8>, byteCount:Int,
		bytePositions:RawPtr<Int32>, bytePositionCount:Int, entryPoint:Int):Int
		return 0;

	public static function native_metadata_validate_debug_sections(sections:RawPtr<HlDebugSection>, count:Int):Int
		return 0;

	public static function native_metadata_validate_code(code:RawPtr<HlNativeCode>):Int
		return 0;

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

	/** Free a native module whose initialization failed before it entered the registry. */
	public static function native_metadata_module_free_shutdown(module:RawPtr<UInt8>):Void {}

	/** Invoke a zero-argument Haxe-owned function with an i32 result. */
	public static function native_metadata_module_call_i32(module:RawPtr<UInt8>, functionIndex:Int):Int
		return 0;

	public static function native_type_function_arity(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_object_field_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_enum_constructor_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_virtual_field_count(type:RawPtr<HlType>):Int
		return 0;
}
