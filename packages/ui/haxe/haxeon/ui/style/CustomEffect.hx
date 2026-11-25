package haxeon.ui.style;

import Equatable;
import haxeon.ui.Color;
import haxeon.ui.style.VisualEffect;

/** Typed value for a native renderer-owned custom shader effect. */
class CustomEffect extends VisualEffect {
	public final definition:CustomEffectDefinition;
	public final parameters:Array<EffectParameter>;
	/** Flattened values written into the backend-neutral layer descriptor. */
	public final components:Array<Float>;

	public function new(definition:CustomEffectDefinition, parameters:Array<EffectParameter>) {
		super(EffectKind.Custom);
		if (definition == null)
			throw "Custom effects require a definition";
		if (parameters == null || parameters.length != definition.parameterCount())
			throw "Custom effect parameter count does not match its definition";
		this.definition = definition;
		this.parameters = [];
		this.components = [];
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			if (parameter == null || parameter.type != definition.parameterTypeAt(index))
				throw "Custom effect parameter type does not match its definition";
			this.parameters.push(parameter);
			for (component in 0...parameter.componentCount)
				this.components.push(parameter.valueAt(component));
		}
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.Custom)
			return false;
		var value:CustomEffect = cast other;
		if (value == null || definition != value.definition || parameters.length != value.parameters.length)
			return false;
		for (index in 0...parameters.length)
			if (parameters[index] != value.parameters[index])
				return false;
		return true;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.Custom)
			return VisualEffect.discrete(this, other, amount);
		var value:CustomEffect = cast other;
		if (value == null || definition != value.definition || parameters.length != value.parameters.length)
			return amount < 0.5 ? copy() : value == null ? copy() : value.copy();
		var result:Array<EffectParameter> = [];
		for (index in 0...parameters.length)
			result.push(parameters[index].interpolate(value.parameters[index], amount));
		return new CustomEffect(definition, result);
	}

	override public function copy():VisualEffect
		return new CustomEffect(definition, parameters);

	override public function inkOverflow():InkOverflow
		return definition.overflow;

	override public function describe():String {
		var values:Array<String> = [];
		for (parameter in parameters)
			values.push(parameter.describe());
		return 'custom(${definition.describe()}: ' + values.join(",") + ')';
	}
}

/**
 * Renderer-owned contract for one custom effect implementation.
 *
 * The ID is stable within the native renderer registration that implements
 * it. Haxe carries only this typed contract; shader source, pipelines, and
 * backend-specific mapping remain native concerns.
 */
struct CustomEffectDefinition implements Equatable {
	public final id:Int;
	public final name:String;
	final parameterTypes:Array<EffectParameterType>;
	public final overflow:InkOverflow;
	public final componentCount:Int;

	public function new(id:Int, name:String, parameterTypes:Array<EffectParameterType>,
			overflow:Null<InkOverflow> = null) {
		if (id <= 0)
			throw "Custom effect registrations require a positive ID";
		if (name == null || name.length == 0)
			throw "Custom effect registrations require a name";
		if (parameterTypes == null)
			throw "Custom effect registrations require parameter types";
		var components = 0;
		for (type in parameterTypes) {
			if (type == null || EffectParameterTypeUtil.componentCount(type) <= 0)
				throw "Custom effect registrations contain an invalid parameter type";
			components += EffectParameterTypeUtil.componentCount(type);
		}
		if (components > 20)
			throw "Custom effect registrations support at most 20 float components";
		this.id = id;
		this.name = name;
		this.parameterTypes = parameterTypes.copy();
		this.overflow = overflow == null ? InkOverflow.zero() : overflow;
		if (!Math.isFinite(this.overflow.left) || !Math.isFinite(this.overflow.top)
			|| !Math.isFinite(this.overflow.right) || !Math.isFinite(this.overflow.bottom))
			throw "Custom effect ink overflow must be finite and non-negative";
		this.componentCount = components;
	}

	public function parameterCount():Int
		return parameterTypes.length;

	public function parameterTypeAt(index:Int):EffectParameterType {
		if (index < 0 || index >= parameterTypes.length)
			throw "Custom effect parameter index is out of range";
		return parameterTypes[index];
	}

	public function equals(other:CustomEffectDefinition):Bool {
		if (id != other.id || name != other.name || componentCount != other.componentCount
			|| overflow != other.overflow || parameterTypes.length != other.parameterTypes.length)
			return false;
		for (index in 0...parameterTypes.length)
			if (parameterTypes[index] != other.parameterTypes[index])
				return false;
		return true;
	}

	public function describe():String
		return name + "#" + id;
}

/** One typed value supplied to a custom effect registration. */
struct EffectParameter implements Equatable {
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
		return type == other.type && componentCount == other.componentCount && x == other.x && y == other.y
			&& z == other.z && w == other.w;

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
		return EffectParameterTypeUtil.label(type) + "(" + text.join(",") + ")";
	}
}

/** Component shape used by a renderer-owned custom effect parameter. */
enum EffectParameterType implements Equatable {
	Float;
	Vec2;
	Vec4;
	Color;
}

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
