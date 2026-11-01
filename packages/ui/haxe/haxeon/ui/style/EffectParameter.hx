package haxeon.ui.style;

import Equatable;
import haxeon.ui.Color;

/** One typed value supplied to a custom effect registration. */
struct EffectParameter : Equatable {
	public final type:EffectParameterType;
	public final componentCount:Int;
	public final x:Float;
	public final y:Float;
	public final z:Float;
	public final w:Float;

	private function new(type:EffectParameterType, x:Float, y:Float, z:Float, w:Float) {
		var count = type == null ? 0 : EffectParameterTypeUtil.componentCount(type);
		if (count == 0)
			throw "Custom effect parameter shape does not match its type";
		this.type = type;
		this.componentCount = count;
		this.x = VisualEffect.requireFinite(x, "Custom effect parameters must be finite");
		this.y = count > 1 ? VisualEffect.requireFinite(y, "Custom effect parameters must be finite") : 0.0;
		this.z = count > 2 ? VisualEffect.requireFinite(z, "Custom effect parameters must be finite") : 0.0;
		this.w = count > 3 ? VisualEffect.requireFinite(w, "Custom effect parameters must be finite") : 0.0;
	}

	public static function scalar(value:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Float, value, 0.0, 0.0, 0.0);

	public static function vec2(x:Float, y:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Vec2, x, y, 0.0, 0.0);

	public static function vec4(x:Float, y:Float, z:Float, w:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Vec4, x, y, z, w);

	public static function color(value:Color):EffectParameter {
		if (value == null)
			throw "Custom color parameters require a color";
		return new EffectParameter(EffectParameterType.Color,
			value.red, value.green, value.blue, value.alpha);
	}

	public function valueAt(index:Int):Float
		return switch index {
			case 0: x;
			case 1 if (componentCount > 1): y;
			case 2 if (componentCount > 2): z;
			case 3 if (componentCount > 3): w;
			default: throw "Custom effect parameter component is out of range";
		};

	public function equals(other:EffectParameter):Bool
		return type == other.type && componentCount == other.componentCount &&
			x == other.x && y == other.y && z == other.z && w == other.w;

	public function interpolate(other:Null<EffectParameter>, amount:Float):EffectParameter {
		if (other == null)
			return this;
		if (type != other.type)
			return amount < 0.5 ? this : other;
		return new EffectParameter(type,
			VisualEffect.interpolateFloat(x, other.x, amount),
			VisualEffect.interpolateFloat(y, other.y, amount),
			VisualEffect.interpolateFloat(z, other.z, amount),
			VisualEffect.interpolateFloat(w, other.w, amount));
	}

	public function describe():String {
		var text:Array<String> = [];
		for (index in 0...componentCount)
			text.push(Std.string(valueAt(index)));
		return Std.string(type) + "(" + text.join(",") + ")";
	}
}
