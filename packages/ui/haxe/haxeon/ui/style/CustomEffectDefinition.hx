package haxeon.ui.style;

import Equatable;

/**
 * Renderer-owned contract for one custom effect implementation.
 *
 * The ID is stable within the native renderer registration that implements
 * it. Haxe carries only this typed contract; shader source, pipelines, and
 * backend-specific mapping remain native concerns.
 */
struct CustomEffectDefinition : Equatable {
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
		if (!Math.isFinite(this.overflow.left) || !Math.isFinite(this.overflow.top) ||
			!Math.isFinite(this.overflow.right) || !Math.isFinite(this.overflow.bottom))
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
