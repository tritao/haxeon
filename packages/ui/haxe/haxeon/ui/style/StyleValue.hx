package haxeon.ui.style;

import haxeon.ui.widgets.layout.Padding;


import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutSelfAlignment;
import haxeon.ui.LayoutWrapMode;
import haxeon.ui.Transform2D;
import haxeon.ui.style.StyleProperty.StylePropertyBase;
import haxeon.ui.style.StyleProperty.StyleColorProperty;
import haxeon.ui.style.StyleProperty.StyleInsetsProperty;
import haxeon.ui.style.StyleProperty.StyleAxisProperty;
import haxeon.ui.style.StyleProperty.StyleTransformProperty;

/** One typed declaration passed to a StyleRule. */
class StyleValue {
	public final property:StylePropertyBase;

	function new(property:StylePropertyBase) {
		if (property == null)
			throw "Style declarations require a property";
		this.property = property;
	}

	/** Applies a declaration without exposing its value as Dynamic. */
	public function applyTo(style:ComputedStyle, source:Null<StyleSource>):Void
		style.setDeclaration(this, source);

	/** Materializes the value for inspection or other explicitly dynamic consumers. */
	public function inspect():Dynamic
		throw "Style declarations require a concrete value kind";

	/** Compares two declarations according to their property's value semantics. */
	public function sameAs(other:StyleValue):Bool
		throw "Style declarations require a concrete value kind";

	/** Collision-free cache key for this property's current value. */
	public function key():String
		throw "Style declarations require a concrete value kind";

	/** Produces a typed interpolated declaration for a property that supports transitions. */
	public function interpolateTo(other:StyleValue, amount:Float):StyleValue
		throw "Style property does not support interpolation";

	/** Copies mutable reference values when a computed style is copied. */
	public function copyForRead():StyleValue {
		if (property == StyleProperty.Decorations) {
			var value = decorationsOf(this);
			return decorations(value == null ? null : value.copy());
		}
		if (property == StyleProperty.Effects || property == StyleProperty.BackdropEffects) {
			var value = effectsOf(this), copy = value == null ? null : value.copy();
			return property == StyleProperty.Effects ? effects(copy) : backdropEffects(copy);
		}
		if (property == StyleProperty.Mask) {
			var value = maskOf(this);
			return mask(value == null ? null : value.copy());
		}
		return this;
	}

	/** Copies exposed reference values at the dynamic inspection boundary. */
	public function inspectForRead():Dynamic {
		if (property == StyleProperty.Decorations) {
			var value = decorationsOf(this);
			return value == null ? null : value.copy();
		}
		if (property == StyleProperty.Effects || property == StyleProperty.BackdropEffects) {
			var value = effectsOf(this);
			return value == null ? null : value.copy();
		}
		if (property == StyleProperty.Mask) {
			var value = maskOf(this);
			return value == null ? null : value.copy();
		}
		return inspect();
	}

	public static inline function colorOf(value:StyleValue):Color return (cast value:StyleColorValue).value;
	public static inline function insetsOf(value:StyleValue):Insets return (cast value:StyleInsetsValue).value;
	public static inline function axisOf(value:StyleValue):LayoutAxis return (cast value:StyleAxisValue).value;
	public static inline function matrixOf(value:StyleValue):Transform2D return (cast value:StyleTransformValue).value;
	public static inline function numberOf(value:StyleValue):Float return (cast value:StyleFloatValue).value;
	public static inline function integerOf(value:StyleValue):Int return (cast value:StyleIntegerValue).value;
	public static inline function booleanOf(value:StyleValue):Bool return (cast value:StyleBoolValue).value;
	public static inline function decorationsOf(value:StyleValue):DecorationChain
		return (cast value:StyleReferenceValue<DecorationChain>).value;
	public static inline function effectsOf(value:StyleValue):EffectChain
		return (cast value:StyleReferenceValue<EffectChain>).value;
	public static inline function maskOf(value:StyleValue):Mask return (cast value:StyleReferenceValue<Mask>).value;

	static var defaultValues:Null<Array<StyleValue>>;

	/** Immutable built-in defaults, constructed once and reused by every resolution. */
	public static function defaults():Array<StyleValue> {
		if (defaultValues != null) return defaultValues;
		var result:Array<StyleValue> = [];
		result.resize(StyleProperty.slotCount());
		result[StyleProperty.Width.slot] = axis(StyleProperty.Width, StyleProperty.Width.defaultValue);
		result[StyleProperty.Height.slot] = axis(StyleProperty.Height, StyleProperty.Height.defaultValue);
		result[StyleProperty.Direction.slot] = new StyleIntegerValue(StyleProperty.Direction, cast StyleProperty.Direction.defaultValue);
		result[StyleProperty.ChildAlignX.slot] = new StyleIntegerValue(StyleProperty.ChildAlignX, cast StyleProperty.ChildAlignX.defaultValue);
		result[StyleProperty.ChildAlignY.slot] = new StyleIntegerValue(StyleProperty.ChildAlignY, cast StyleProperty.ChildAlignY.defaultValue);
		result[StyleProperty.ChildDistribution.slot] = new StyleIntegerValue(StyleProperty.ChildDistribution, cast StyleProperty.ChildDistribution.defaultValue);
		result[StyleProperty.Positioning.slot] = new StyleIntegerValue(StyleProperty.Positioning, cast StyleProperty.Positioning.defaultValue);
		result[StyleProperty.AspectRatio.slot] = number(StyleProperty.AspectRatio, StyleProperty.AspectRatio.defaultValue);
		result[StyleProperty.WrapMode.slot] = new StyleIntegerValue(StyleProperty.WrapMode, cast StyleProperty.WrapMode.defaultValue);
		result[StyleProperty.RowGap.slot] = number(StyleProperty.RowGap, StyleProperty.RowGap.defaultValue);
		result[StyleProperty.ColumnGap.slot] = number(StyleProperty.ColumnGap, StyleProperty.ColumnGap.defaultValue);
		result[StyleProperty.AlignSelf.slot] = new StyleIntegerValue(StyleProperty.AlignSelf, cast StyleProperty.AlignSelf.defaultValue);
		result[StyleProperty.PositionX.slot] = number(StyleProperty.PositionX, StyleProperty.PositionX.defaultValue);
		result[StyleProperty.PositionY.slot] = number(StyleProperty.PositionY, StyleProperty.PositionY.defaultValue);
		result[StyleProperty.ZIndex.slot] = new StyleIntegerValue(StyleProperty.ZIndex, cast StyleProperty.ZIndex.defaultValue);
		result[StyleProperty.Overlay.slot] = boolean(StyleProperty.Overlay, StyleProperty.Overlay.defaultValue);
		result[StyleProperty.ClipToParent.slot] = boolean(StyleProperty.ClipToParent, StyleProperty.ClipToParent.defaultValue);
		result[StyleProperty.Padding.slot] = insets(StyleProperty.Padding, StyleProperty.Padding.defaultValue);
		result[StyleProperty.ChildGap.slot] = number(StyleProperty.ChildGap, StyleProperty.ChildGap.defaultValue);
		result[StyleProperty.Background.slot] = color(StyleProperty.Background, StyleProperty.Background.defaultValue);
		result[StyleProperty.RadiusTopLeft.slot] = number(StyleProperty.RadiusTopLeft, StyleProperty.RadiusTopLeft.defaultValue);
		result[StyleProperty.RadiusTopRight.slot] = number(StyleProperty.RadiusTopRight, StyleProperty.RadiusTopRight.defaultValue);
		result[StyleProperty.RadiusBottomRight.slot] = number(StyleProperty.RadiusBottomRight, StyleProperty.RadiusBottomRight.defaultValue);
		result[StyleProperty.RadiusBottomLeft.slot] = number(StyleProperty.RadiusBottomLeft, StyleProperty.RadiusBottomLeft.defaultValue);
		result[StyleProperty.ClipHorizontal.slot] = boolean(StyleProperty.ClipHorizontal, StyleProperty.ClipHorizontal.defaultValue);
		result[StyleProperty.ClipVertical.slot] = boolean(StyleProperty.ClipVertical, StyleProperty.ClipVertical.defaultValue);
		result[StyleProperty.Visible.slot] = boolean(StyleProperty.Visible, StyleProperty.Visible.defaultValue);
		result[StyleProperty.Transform.slot] = matrix(StyleProperty.Transform, StyleProperty.Transform.defaultValue);
		result[StyleProperty.TransformOriginX.slot] = number(StyleProperty.TransformOriginX, StyleProperty.TransformOriginX.defaultValue);
		result[StyleProperty.TransformOriginY.slot] = number(StyleProperty.TransformOriginY, StyleProperty.TransformOriginY.defaultValue);
		result[StyleProperty.BorderColor.slot] = color(StyleProperty.BorderColor, StyleProperty.BorderColor.defaultValue);
		result[StyleProperty.BorderWidth.slot] = number(StyleProperty.BorderWidth, StyleProperty.BorderWidth.defaultValue);
		result[StyleProperty.OutlineColor.slot] = color(StyleProperty.OutlineColor, StyleProperty.OutlineColor.defaultValue);
		result[StyleProperty.OutlineWidth.slot] = number(StyleProperty.OutlineWidth, StyleProperty.OutlineWidth.defaultValue);
		result[StyleProperty.ShadowColor.slot] = color(StyleProperty.ShadowColor, StyleProperty.ShadowColor.defaultValue);
		result[StyleProperty.ShadowOffsetX.slot] = number(StyleProperty.ShadowOffsetX, StyleProperty.ShadowOffsetX.defaultValue);
		result[StyleProperty.ShadowOffsetY.slot] = number(StyleProperty.ShadowOffsetY, StyleProperty.ShadowOffsetY.defaultValue);
		result[StyleProperty.ShadowBlur.slot] = number(StyleProperty.ShadowBlur, StyleProperty.ShadowBlur.defaultValue);
		result[StyleProperty.ShadowSpread.slot] = number(StyleProperty.ShadowSpread, StyleProperty.ShadowSpread.defaultValue);
		result[StyleProperty.Decorations.slot] = decorations(StyleProperty.Decorations.defaultValue);
		result[StyleProperty.Opacity.slot] = number(StyleProperty.Opacity, StyleProperty.Opacity.defaultValue);
		result[StyleProperty.Effects.slot] = effects(StyleProperty.Effects.defaultValue);
		result[StyleProperty.BackdropEffects.slot] = backdropEffects(StyleProperty.BackdropEffects.defaultValue);
		result[StyleProperty.Mask.slot] = mask(StyleProperty.Mask.defaultValue);
		result[StyleProperty.ProgressTrackColor.slot] = color(StyleProperty.ProgressTrackColor, StyleProperty.ProgressTrackColor.defaultValue);
		result[StyleProperty.ProgressFillColor.slot] = color(StyleProperty.ProgressFillColor, StyleProperty.ProgressFillColor.defaultValue);
		result[StyleProperty.SliderTrackColor.slot] = color(StyleProperty.SliderTrackColor, StyleProperty.SliderTrackColor.defaultValue);
		result[StyleProperty.SliderFillColor.slot] = color(StyleProperty.SliderFillColor, StyleProperty.SliderFillColor.defaultValue);
		result[StyleProperty.SliderThumbColor.slot] = color(StyleProperty.SliderThumbColor, StyleProperty.SliderThumbColor.defaultValue);
		result[StyleProperty.TextColor.slot] = color(StyleProperty.TextColor, StyleProperty.TextColor.defaultValue);
		result[StyleProperty.FontSize.slot] = number(StyleProperty.FontSize, StyleProperty.FontSize.defaultValue);
		result[StyleProperty.LetterSpacing.slot] = number(StyleProperty.LetterSpacing, StyleProperty.LetterSpacing.defaultValue);
		for (property in StyleProperty.all())
			if (result[property.slot] == null) throw 'Missing typed default for ${property.name}';
		defaultValues = result;
		return result;
	}

	/** Creates a typed declaration for an arbitrary property of the corresponding kind. */
	public static function number(property:StyleProperty<Float>, value:Float):StyleValue
		return new StyleFloatValue(property, value);
	public static function color(property:StyleColorProperty, value:Color):StyleValue
		return new StyleColorValue(property, value);
	public static function boolean(property:StyleProperty<Bool>, value:Bool):StyleValue
		return new StyleBoolValue(property, value);
	public static function integer(property:StyleProperty<Int>, value:Int):StyleValue
		return new StyleIntegerValue(property, value);
	public static function integerProperty(property:StylePropertyBase, value:Int):StyleValue
		return new StyleIntegerValue(property, value);
	public static function axis(property:StyleAxisProperty, value:LayoutAxis):StyleValue
		return new StyleAxisValue(property, value);
	public static function insets(property:StyleInsetsProperty, value:Insets):StyleValue
		return new StyleInsetsValue(property, value);
	public static function matrix(property:StyleTransformProperty, value:Transform2D):StyleValue
		return new StyleTransformValue(property, value);

	public static function width(value:LayoutAxis):StyleValue
		return new StyleAxisValue(StyleProperty.Width, value);

	public static function height(value:LayoutAxis):StyleValue
		return new StyleAxisValue(StyleProperty.Height, value);

	public static function direction(value:LayoutDirection):StyleValue
		return new StyleIntegerValue(StyleProperty.Direction, cast value);

	public static function alignX(value:LayoutAlignmentX):StyleValue
		return new StyleIntegerValue(StyleProperty.ChildAlignX, cast value);

	public static function alignY(value:LayoutAlignmentY):StyleValue
		return new StyleIntegerValue(StyleProperty.ChildAlignY, cast value);

	public static function distribution(value:LayoutDistribution):StyleValue
		return new StyleIntegerValue(StyleProperty.ChildDistribution, cast value);

	public static function positioning(value:LayoutPositioning):StyleValue
		return new StyleIntegerValue(StyleProperty.Positioning, cast value);

	public static function aspectRatio(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.AspectRatio, value);

	public static function wrapMode(value:LayoutWrapMode):StyleValue
		return new StyleIntegerValue(StyleProperty.WrapMode, cast value);

	public static function rowGap(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.RowGap, value);

	public static function columnGap(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.ColumnGap, value);

	public static function alignSelf(value:LayoutSelfAlignment):StyleValue
		return new StyleIntegerValue(StyleProperty.AlignSelf, cast value);

	public static function background(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.Background, value);

	public static function padding(value:Insets):StyleValue
		return new StyleInsetsValue(StyleProperty.Padding, value);

	public static function transform(value:Transform2D):StyleValue
		return new StyleTransformValue(StyleProperty.Transform, value);

	public static function paddingSymmetric(horizontal:Float, vertical:Float):StyleValue
		return padding(new Insets(horizontal, vertical, horizontal, vertical));

	public static function radius(property:StyleProperty<Float>, value:Float):StyleValue
		return new StyleFloatValue(property, value);

	public static function radiusAll(value:Float):Array<StyleValue>
		return [radius(StyleProperty.RadiusTopLeft, value), radius(StyleProperty.RadiusTopRight, value),
			radius(StyleProperty.RadiusBottomRight, value), radius(StyleProperty.RadiusBottomLeft, value)];

	public static function textColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.TextColor, value);

	public static function fontSize(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.FontSize, value);

	public static function letterSpacing(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.LetterSpacing, value);

	public static function borderColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.BorderColor, value);

	public static function borderWidth(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.BorderWidth, value);

	public static function outlineColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.OutlineColor, value);

	public static function outlineWidth(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.OutlineWidth, value);

	public static function shadowColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.ShadowColor, value);

	public static function shadowOffset(x:Float, y:Float):Array<StyleValue>
		return [new StyleFloatValue(StyleProperty.ShadowOffsetX, x), new StyleFloatValue(StyleProperty.ShadowOffsetY, y)];

	public static function shadowBlur(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.ShadowBlur, value);

	public static function shadowSpread(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.ShadowSpread, value);

	public static function decorations(value:DecorationChain):StyleValue
		return new StyleReferenceValue(StyleProperty.Decorations, value);

	public static function opacity(value:Float):StyleValue
		return new StyleFloatValue(StyleProperty.Opacity, value);

	public static function effects(value:EffectChain):StyleValue
		return new StyleReferenceValue(StyleProperty.Effects, value);
	public static function effectProperty(property:StyleProperty<EffectChain>, value:EffectChain):StyleValue
		return new StyleReferenceValue(property, value);

	public static function backdropEffects(value:EffectChain):StyleValue
		return new StyleReferenceValue(StyleProperty.BackdropEffects, value);

	public static function mask(value:Mask):StyleValue
		return new StyleReferenceValue(StyleProperty.Mask, value);

	public static function progressTrackColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.ProgressTrackColor, value);

	public static function progressFillColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.ProgressFillColor, value);

	public static function sliderTrackColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.SliderTrackColor, value);

	public static function sliderFillColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.SliderFillColor, value);

	public static function sliderThumbColor(value:Color):StyleValue
		return new StyleColorValue(StyleProperty.SliderThumbColor, value);

}

private class StyleColorValue extends StyleValue {
	public final value:Color;
	public function new(property:StyleColorProperty, value:Color) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return value.red + "," + value.green + "," + value.blue + "," + value.alpha;
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleColorValue) &&
			(cast property:StyleColorProperty).sameColor(value, (cast other:StyleColorValue).value);
	override public function interpolateTo(other:StyleValue, amount:Float):StyleValue {
		var typed:StyleColorProperty = cast property;
		if (!typed.hasInterpolation || other.property != property) throw "Style property does not support interpolation";
		return new StyleColorValue(typed, typed.interpolateColor(value, (cast other:StyleColorValue).value, amount));
	}
}

private class StyleInsetsValue extends StyleValue {
	public final value:Insets;
	public function new(property:StyleInsetsProperty, value:Insets) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return value.left + "," + value.top + "," + value.right + "," + value.bottom;
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleInsetsValue) &&
			(cast property:StyleInsetsProperty).sameInsets(value, (cast other:StyleInsetsValue).value);
}

private class StyleAxisValue extends StyleValue {
	public final value:LayoutAxis;
	public function new(property:StyleAxisProperty, value:LayoutAxis) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return Std.string(value.sizing) + "," + value.value + "," + value.min + "," + value.max + "," + value.growWeight;
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleAxisValue) &&
			(cast property:StyleAxisProperty).sameAxis(value, (cast other:StyleAxisValue).value);
}

private class StyleTransformValue extends StyleValue {
	public final value:Transform2D;
	public function new(property:StyleTransformProperty, value:Transform2D) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return value.a + "," + value.b + "," + value.c + "," + value.d + "," + value.tx + "," + value.ty;
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleTransformValue) &&
			(cast property:StyleTransformProperty).sameTransform(value, (cast other:StyleTransformValue).value);
}

private class StyleFloatValue extends StyleValue {
	public final value:Float;
	public function new(property:StyleProperty<Float>, value:Float) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return Std.string(value);
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleFloatValue) &&
			value == (cast other:StyleFloatValue).value;
	override public function interpolateTo(other:StyleValue, amount:Float):StyleValue {
		var typed:StyleProperty<Float> = cast property, interpolate = typed.interpolate;
		if (interpolate == null || other.property != property) throw "Style property does not support interpolation";
		return new StyleFloatValue(typed, interpolate(value, (cast other:StyleFloatValue).value, amount));
	}
}

private class StyleIntegerValue extends StyleValue {
	public final value:Int;
	public function new(property:StylePropertyBase, value:Int) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return Std.string(value);
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleIntegerValue) &&
			value == (cast other:StyleIntegerValue).value;
}

private class StyleBoolValue extends StyleValue {
	public final value:Bool;
	public function new(property:StyleProperty<Bool>, value:Bool) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String return Std.string(value);
	override public function sameAs(other:StyleValue):Bool
		return other != null && property == other.property && Std.isOfType(other, StyleBoolValue) &&
			value == (cast other:StyleBoolValue).value;
}

private class StyleReferenceValue<T> extends StyleValue {
	public final value:T;
	public function new(property:StyleProperty<T>, value:T) { super(property); this.value = value; }
	override public function inspect():Dynamic return value;
	override public function key():String {
		if (value == null) return "null";
		if (property == StyleProperty.Effects || property == StyleProperty.BackdropEffects) return StyleValue.effectsOf(this).key();
		if (property == StyleProperty.Decorations) return StyleValue.decorationsOf(this).key();
		if (property == StyleProperty.Mask) return StyleValue.maskOf(this).describe();
		throw 'No typed cache key for ${property.name}';
	}
	override public function sameAs(other:StyleValue):Bool {
		if (other == null || property != other.property) return false;
		if (property == StyleProperty.Decorations) {
			var left = StyleValue.decorationsOf(this), right = StyleValue.decorationsOf(other);
			return left == right || (left != null && right != null && left.isEqual(right));
		}
		if (property == StyleProperty.Effects || property == StyleProperty.BackdropEffects) {
			var left = StyleValue.effectsOf(this), right = StyleValue.effectsOf(other);
			return left == right || (left != null && right != null && left.isEqual(right));
		}
		if (property == StyleProperty.Mask) {
			var left = StyleValue.maskOf(this), right = StyleValue.maskOf(other);
			return left == right || (left != null && right != null && left.isEqual(right));
		}
		throw 'Unknown reference property ${property.name}';
	}
	override public function interpolateTo(other:StyleValue, amount:Float):StyleValue {
		var typed:StyleProperty<T> = cast property, interpolate = typed.interpolate;
		if (interpolate == null || other.property != property) throw "Style property does not support interpolation";
		return new StyleReferenceValue(typed, interpolate(value, (cast other:StyleReferenceValue<T>).value, amount));
	}
}
