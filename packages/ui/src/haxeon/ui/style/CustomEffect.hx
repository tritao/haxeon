package haxeon.ui.style;

import Equatable;
import haxeon.ui.Color;
import haxeon.ui.style.VisualEffect;

/** Typed value for a native renderer-owned custom shader effect. */
class CustomEffect extends VisualEffect {
	/** The effect the renderer implements. */
	public final definition:CustomEffectDefinition;

	/** The values given for the definition's parameters, in order. */
	public final parameters:Array<EffectParameter>;
	/** Flattened values written into the backend-neutral layer descriptor. */
	public final components:Array<Float>;

	/** An instance of `definition` with `parameters`. Throws when they do not match the definition's types. */
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
	/** The ID the native renderer registered the effect under: positive. */
	public final id:Int;
	/** The effect's name, for inspection. */
	public final name:String;
	final parameterTypes:Array<EffectParameterType>;
	/** How far the effect may draw outside the box, so the renderer leaves room. */
	public final overflow:InkOverflow;
	/** How many numbers all its parameters take together. */
	public final componentCount:Int;

	/**
	 * The contract of the native effect `id`, taking parameters of `parameterTypes`. Throws when `id` is not positive.
	 */
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
			if (type == null || type.componentCount <= 0)
				throw "Custom effect registrations contain an invalid parameter type";
			components += type.componentCount;
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

	/** How many parameters it takes. */
	public function parameterCount():Int
		return parameterTypes.length;

	/** The type of the parameter at `index`. */
	public function parameterTypeAt(index:Int):EffectParameterType {
		if (index < 0 || index >= parameterTypes.length)
			throw "Custom effect parameter index is out of range";
		return parameterTypes[index];
	}

	/** Whether `other` describes the same effect. */
	public function equals(other:CustomEffectDefinition):Bool {
		if (id != other.id || name != other.name || componentCount != other.componentCount
			|| overflow != other.overflow || parameterTypes.length != other.parameterTypes.length)
			return false;
		for (index in 0...parameterTypes.length)
			if (parameterTypes[index] != other.parameterTypes[index])
				return false;
		return true;
	}

	/** A description for inspection. */
	public function describe():String
		return name + "#" + id;
}

/** One typed value supplied to a custom effect registration. */
struct EffectParameter implements Equatable {
	/** The parameter's type. */
	public final type:EffectParameterType;
	/** How many of `x`, `y`, `z` and `w` it uses. */
	public final componentCount:Int;
	/** The first component. */
	public final x:Float;
	/** The second component. */
	public final y:Float;
	/** The third component. */
	public final z:Float;
	/** The fourth component. */
	public final w:Float;

	private function new(type:EffectParameterType, x:Float, y:Float, z:Float, w:Float) {
		var count = type == null ? 0 : type.componentCount;
		if (count == 0)
			throw "Custom effect parameter shape does not match its type";
		this.type = type;
		this.componentCount = count;
		this.x = VisualEffect.requireFinite(x, "Custom effect parameters must be finite");
		this.y = count > 1 ? VisualEffect.requireFinite(y, "Custom effect parameters must be finite") : 0.0;
		this.z = count > 2 ? VisualEffect.requireFinite(z, "Custom effect parameters must be finite") : 0.0;
		this.w = count > 3 ? VisualEffect.requireFinite(w, "Custom effect parameters must be finite") : 0.0;
	}

	/** A single number. */
	public static function scalar(value:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Float, value, 0.0, 0.0, 0.0);

	/** Two numbers. */
	public static function vec2(x:Float, y:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Vec2, x, y, 0.0, 0.0);

	/** Four numbers. */
	public static function vec4(x:Float, y:Float, z:Float, w:Float):EffectParameter
		return new EffectParameter(EffectParameterType.Vec4, x, y, z, w);

	/** A color, as red, green, blue and alpha. */
	public static function color(value:Color):EffectParameter {
		if (value == null)
			throw "Custom color parameters require a color";
		return new EffectParameter(EffectParameterType.Color,
			value.red, value.green, value.blue, value.alpha);
	}

	/** The component at `index`, from 0 to 3. */
	public function valueAt(index:Int):Float
		return switch index {
			case 0: x;
			case 1 if (componentCount > 1): y;
			case 2 if (componentCount > 2): z;
			case 3 if (componentCount > 3): w;
			default: throw "Custom effect parameter component is out of range";
		};

	/** Whether `other` has the same type and components. */
	public function equals(other:EffectParameter):Bool
		return type == other.type && componentCount == other.componentCount && x == other.x && y == other.y
			&& z == other.z && w == other.w;

	/** The value `amount` of the way to `other`, for transitions; jumps halfway when the types differ. */
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

	/** A description for inspection. */
	public function describe():String {
		var text:Array<String> = [];
		for (index in 0...componentCount)
			text.push(Std.string(valueAt(index)));
		return type.label + "(" + text.join(",") + ")";
	}
}

/** Component shape used by a renderer-owned custom effect parameter. */
enum EffectParameterType implements Equatable {
	/** How many numbers a parameter of this type takes. */
	public final componentCount:Int;

	/** The type's name, as shaders spell it. */
	public final label:String;

	/** One number. */
	Float {
		componentCount:1, label:"float"
	};

	/** Two numbers. */
	Vec2 {componentCount: 2, label: "vec2"};

	/** Four numbers. */
	Vec4 {componentCount: 4, label: "vec4"};

	/** A color. */
	Color {componentCount: 4, label: "color"};
}
