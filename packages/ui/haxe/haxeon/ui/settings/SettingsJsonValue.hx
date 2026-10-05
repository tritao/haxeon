package haxeon.ui.settings;

/**
 * Runtime type checks on parsed JSON values.
 *
 * Kept apart from files that import PropertyValue, whose Bool/Int/Float
 * constructors would shadow the standard types in Std.isOfType.
 */
class SettingsJsonValue {
	public static function isBool(value:Dynamic):Bool
		return value != null && Std.isOfType(value, Bool);

	public static function isInt(value:Dynamic):Bool
		return value != null && Std.isOfType(value, Int);

	public static function isFloat(value:Dynamic):Bool
		return value != null && Std.isOfType(value, Float);

	public static function isString(value:Dynamic):Bool
		return value != null && Std.isOfType(value, String);

	public static function isArray(value:Dynamic):Bool
		return value != null && Std.isOfType(value, Array);
}
