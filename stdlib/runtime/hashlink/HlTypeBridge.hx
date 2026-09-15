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

	public static function native_type_function_arity(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_object_field_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_enum_constructor_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_virtual_field_count(type:RawPtr<HlType>):Int
		return 0;
}
