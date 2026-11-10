package haxeon.ui.style;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.style.StyleProperty.StylePropertyBase;
import haxeon.ui.style.StyleProperty.StyleColorProperty;
import haxeon.ui.style.StyleProperty.StyleInsetsProperty;
import haxeon.ui.style.StyleProperty.StyleAxisProperty;
import haxeon.ui.style.StyleProperty.StyleTransformProperty;

private class InheritedKeyCache {
	public var key:Null<String> = null;
	public function new() {}
}

/** Authoritative Haxe-side result of style resolution. Values remain in their typed declarations. */
class ComputedStyle {
	var values:Array<StyleValue>;
	var sources:Array<Null<StyleSource>>;
	public var matchingRules(default, null):Array<StyleSource>;
	var shared:Bool;
	var rulesShared:Bool;
	var inheritedKeyCache:Null<InheritedKeyCache>;

	/** With `from`, storage is shared until either style is changed. */
	public function new(?from:ComputedStyle) {
		if (from == null) {
			values = [];
			sources = [];
			matchingRules = [];
		} else {
			values = from.values;
			sources = from.sources;
			matchingRules = from.matchingRules;
			from.shared = true;
			from.rulesShared = true;
		}
		shared = from != null;
		rulesShared = from != null;
		inheritedKeyCache = null;
	}

	/** Stores an immutable typed declaration. */
	public function setDeclaration(value:StyleValue, source:Null<StyleSource>):Void {
		if (value == null) throw "Computed styles require a declaration";
		ensureWritable();
		var property = value.property;
		if (property.inherited) inheritedKeyCache = null;
		var slot = property.slot;
		if (slot >= values.length) { values.resize(slot + 1); sources.resize(slot + 1); }
		values[slot] = value;
		sources[slot] = source;
	}

	public function setColor(property:StyleColorProperty, value:Color, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.color(property, value), source);
	public function setInsets(property:StyleInsetsProperty, value:Insets, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.insets(property, value), source);
	public function setAxis(property:StyleAxisProperty, value:LayoutAxis, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.axis(property, value), source);
	public function setMatrix(property:StyleTransformProperty, value:Transform2D, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.matrix(property, value), source);
	public function setNumber(property:StyleProperty<Float>, value:Float, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.number(property, value), source);
	public function setInteger(property:StyleProperty<Int>, value:Int, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.integer(property, value), source);
	public function setBoolean(property:StyleProperty<Bool>, value:Bool, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.boolean(property, value), source);
	public function setDecorations(value:DecorationChain, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.decorations(value), source);
	public function setEffects(property:StyleProperty<EffectChain>, value:EffectChain, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.effectProperty(property, value), source);
	public function setMask(value:Mask, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.mask(value), source);

	inline function isSet(slot:Int):Bool return slot < values.length && values[slot] != null;
	inline function valueAt(slot:Int):Null<StyleValue> return slot < values.length ? values[slot] : null;
	inline function sourceAt(slot:Int):Null<StyleSource> return slot < sources.length ? sources[slot] : null;

	public function has(property:StylePropertyBase):Bool return property != null && isSet(property.slot);
	public function source(property:StylePropertyBase):Null<StyleSource> return sourceAt(property.slot);
	/** Internal typed value access, including null-valued reference declarations. */
	@:allow(haxeon.ui.style.StyleResolver)
	function declaration(property:StylePropertyBase):Null<StyleValue> return valueAt(property.slot);

	public function getColor(property:StyleColorProperty):Color {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.colorOf(value);
	}
	public function getInsets(property:StyleInsetsProperty):Insets {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.insetsOf(value);
	}
	public function getAxis(property:StyleAxisProperty):LayoutAxis {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.axisOf(value);
	}
	public function getMatrix(property:StyleTransformProperty):Transform2D {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.matrixOf(value);
	}
	public function getNumber(property:StyleProperty<Float>):Float {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.numberOf(value);
	}
	public function getInteger(property:StyleProperty<Int>):Int {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.integerOf(value);
	}
	public function getBoolean(property:StyleProperty<Bool>):Bool {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.booleanOf(value);
	}
	public function getDecorations():DecorationChain {
		var value = valueAt(StyleProperty.Decorations.slot);
		if (value == null) return StyleProperty.Decorations.defaultValue;
		var result = StyleValue.decorationsOf(value); return result == null ? null : result.copy();
	}
	public function getDecorationsReadOnly():DecorationChain {
		var value = valueAt(StyleProperty.Decorations.slot);
		return value == null ? StyleProperty.Decorations.defaultValue : StyleValue.decorationsOf(value);
	}
	public function getEffects(property:StyleProperty<EffectChain>):EffectChain {
		var value = valueAt(property.slot);
		if (value == null) return property.defaultValue;
		var result = StyleValue.effectsOf(value); return result == null ? null : result.copy();
	}
	public function getEffectsReadOnly(property:StyleProperty<EffectChain>):EffectChain {
		var value = valueAt(property.slot); return value == null ? property.defaultValue : StyleValue.effectsOf(value);
	}
	public function getMask():Mask {
		var value = valueAt(StyleProperty.Mask.slot);
		if (value == null) return StyleProperty.Mask.defaultValue;
		var result = StyleValue.maskOf(value); return result == null ? null : result.copy();
	}
	public function getMaskReadOnly():Mask {
		var value = valueAt(StyleProperty.Mask.slot);
		return value == null ? StyleProperty.Mask.defaultValue : StyleValue.maskOf(value);
	}

	public function sharesValuesWith(other:Null<ComputedStyle>):Bool return other != null && values == other.values;
	@:allow(haxeon.ui.style.StyleDiff)
	function sameValue(property:StylePropertyBase, other:ComputedStyle):Bool
		return values[property.slot].sameAs(other.values[property.slot]);

	public function recordMatch(source:StyleSource):Void {
		if (source != null) {
			if (rulesShared) { matchingRules = matchingRules.copy(); rulesShared = false; }
			matchingRules.push(source);
		}
	}
	public function matchingStyleRules():Array<StyleSource> return matchingRules.copy();
	public function entries():Array<StyleInspectionEntry> {
		var result:Array<StyleInspectionEntry> = [];
		for (property in StyleProperty.all())
			if (isSet(property.slot)) result.push(new StyleInspectionEntry(property.name,
				values[property.slot].inspectForRead(), sourceAt(property.slot)));
		return result;
	}
	@:allow(haxeon.ui.debug.UiInspector)
	function copyInspectionValues():Void {
		for (property in StyleProperty.all())
			if (property.copiedOnRead && isSet(property.slot)) values[property.slot].inspectForRead();
	}

	/** Materializes the resolved layout subset without mutating any input style. */
	public function toLayoutStyle(?base:LayoutStyle):LayoutStyle {
		var result = base == null ? new LayoutStyle() : base.copy();
		if (isSet(StyleProperty.Width.slot)) result.width = getAxis(StyleProperty.Width);
		if (isSet(StyleProperty.Height.slot)) result.height = getAxis(StyleProperty.Height);
		if (isSet(StyleProperty.Direction.slot)) result.direction = StyleValue.directionOf(values[StyleProperty.Direction.slot]);
		if (isSet(StyleProperty.ChildAlignX.slot)) result.childAlignX = StyleValue.alignmentXOf(values[StyleProperty.ChildAlignX.slot]);
		if (isSet(StyleProperty.ChildAlignY.slot)) result.childAlignY = StyleValue.alignmentYOf(values[StyleProperty.ChildAlignY.slot]);
		if (isSet(StyleProperty.ChildDistribution.slot)) result.childDistribution = StyleValue.distributionOf(values[StyleProperty.ChildDistribution.slot]);
		if (isSet(StyleProperty.Positioning.slot)) result.positioning = StyleValue.positioningOf(values[StyleProperty.Positioning.slot]);
		if (isSet(StyleProperty.AspectRatio.slot)) result.aspectRatio = getNumber(StyleProperty.AspectRatio);
		if (isSet(StyleProperty.WrapMode.slot)) result.wrapMode = StyleValue.wrapModeOf(values[StyleProperty.WrapMode.slot]);
		if (isSet(StyleProperty.RowGap.slot)) result.rowGap = getNumber(StyleProperty.RowGap);
		if (isSet(StyleProperty.ColumnGap.slot)) result.columnGap = getNumber(StyleProperty.ColumnGap);
		if (isSet(StyleProperty.AlignSelf.slot)) result.alignSelf = StyleValue.selfAlignmentOf(values[StyleProperty.AlignSelf.slot]);
		if (isSet(StyleProperty.PositionX.slot)) result.positionX = getNumber(StyleProperty.PositionX);
		if (isSet(StyleProperty.PositionY.slot)) result.positionY = getNumber(StyleProperty.PositionY);
		if (isSet(StyleProperty.ZIndex.slot)) result.zIndex = getInteger(StyleProperty.ZIndex);
		if (isSet(StyleProperty.Overlay.slot)) result.overlay = getBoolean(StyleProperty.Overlay);
		if (isSet(StyleProperty.ClipToParent.slot)) result.clipToParent = getBoolean(StyleProperty.ClipToParent);
		if (isSet(StyleProperty.Padding.slot)) result.padding = getInsets(StyleProperty.Padding);
		if (isSet(StyleProperty.ChildGap.slot)) result.childGap = getNumber(StyleProperty.ChildGap);
		if (isSet(StyleProperty.Background.slot)) result.background = getColor(StyleProperty.Background);
		if (isSet(StyleProperty.RadiusTopLeft.slot)) result.radiusTopLeft = getNumber(StyleProperty.RadiusTopLeft);
		if (isSet(StyleProperty.RadiusTopRight.slot)) result.radiusTopRight = getNumber(StyleProperty.RadiusTopRight);
		if (isSet(StyleProperty.RadiusBottomRight.slot)) result.radiusBottomRight = getNumber(StyleProperty.RadiusBottomRight);
		if (isSet(StyleProperty.RadiusBottomLeft.slot)) result.radiusBottomLeft = getNumber(StyleProperty.RadiusBottomLeft);
		if (isSet(StyleProperty.ClipHorizontal.slot)) result.clipHorizontal = getBoolean(StyleProperty.ClipHorizontal);
		if (isSet(StyleProperty.ClipVertical.slot)) result.clipVertical = getBoolean(StyleProperty.ClipVertical);
		if (isSet(StyleProperty.Visible.slot)) result.visible = getBoolean(StyleProperty.Visible);
		if (isSet(StyleProperty.Transform.slot)) result.transform = getMatrix(StyleProperty.Transform);
		if (isSet(StyleProperty.TransformOriginX.slot)) result.transformOriginX = getNumber(StyleProperty.TransformOriginX);
		if (isSet(StyleProperty.TransformOriginY.slot)) result.transformOriginY = getNumber(StyleProperty.TransformOriginY);
		return result;
	}

	public function copy():ComputedStyle {
		var result = new ComputedStyle();
		for (property in StyleProperty.all())
			if (isSet(property.slot)) result.setDeclaration(values[property.slot].copyForRead(), sourceAt(property.slot));
		for (source in matchingRules) result.recordMatch(source);
		return result;
	}
	public function fork():ComputedStyle {
		if (inheritedKeyCache == null) inheritedKeyCache = new InheritedKeyCache();
		var result = new ComputedStyle(this);
		result.inheritedKeyCache = inheritedKeyCache;
		shared = true; rulesShared = true;
		return result;
	}
	public function cachedInheritedKey():Null<String> return inheritedKeyCache == null ? null : inheritedKeyCache.key;
	public function rememberInheritedKey(key:String):Void {
		if (inheritedKeyCache == null) inheritedKeyCache = new InheritedKeyCache();
		inheritedKeyCache.key = key;
	}
	function ensureWritable():Void {
		if (!shared) return;
		values = values.copy(); sources = sources.copy(); shared = false;
	}
}
