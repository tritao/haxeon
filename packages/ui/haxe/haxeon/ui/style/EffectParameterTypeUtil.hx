package haxeon.ui.style;

import haxeon.ui.Color;

/** Explicit parameter metadata and display labels, independent of enum representation. */
class EffectParameterTypeUtil {
	public static function componentCount(type:EffectParameterType):Int {
		if (type == null) return 0;
		return switch type {
			case EffectParameterType.Float: 1;
			case EffectParameterType.Vec2: 2;
			case EffectParameterType.Vec4 | EffectParameterType.Color: 4;
		};
	}
	public static function label(type:EffectParameterType):String {
		return switch type {
			case EffectParameterType.Float: "float";
			case EffectParameterType.Vec2: "vec2";
			case EffectParameterType.Vec4: "vec4";
			case EffectParameterType.Color: "color";
		};
	}
}
