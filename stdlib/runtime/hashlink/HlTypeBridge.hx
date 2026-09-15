package runtime.hashlink;

import runtime.memory.RawPtr;

/** Small native boundary for handing Haxe-owned type metadata to HashLink. */
@:hlNative("haxeon_runtime")
class HlTypeBridge {
	public static function native_type_kind(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_size(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_data_size(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_object_field_offset(type:RawPtr<HlType>, field:Int):Int
		return 0;

	public static function native_type_initialize_object(type:RawPtr<HlType>):Void {}

	public static function native_type_initialize_enum(type:RawPtr<HlType>, context:RawPtr<HlModuleContext>):Void {}

	public static function native_type_initialize_virtual(type:RawPtr<HlType>, context:RawPtr<HlModuleContext>):Void {}

	public static function native_metadata_initialize(types:RawPtr<RawPtr<HlType>>, count:Int, context:RawPtr<HlModuleContext>):Void {}

	public static function native_module_context_dispose(context:RawPtr<HlModuleContext>):Void {}

	public static function native_type_function_arity(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_object_field_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_enum_constructor_count(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_virtual_field_count(type:RawPtr<HlType>):Int
		return 0;
}
