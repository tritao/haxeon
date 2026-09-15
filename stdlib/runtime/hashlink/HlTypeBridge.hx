package runtime.hashlink;

import runtime.memory.RawPtr;

/** Small native boundary for handing Haxe-owned type metadata to HashLink. */
@:hlNative("haxeon_runtime")
class HlTypeBridge {
	public static function native_type_kind(type:RawPtr<HlType>):Int
		return 0;

	public static function native_type_size(type:RawPtr<HlType>):Int
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
