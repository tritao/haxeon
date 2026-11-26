package haxeon.ui.style;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.StyleProperty.StyleAxisProperty;
import haxeon.ui.style.StyleProperty.StyleColorProperty;
import haxeon.ui.style.StyleProperty.StyleInsetsProperty;
import haxeon.ui.style.StyleProperty.StylePropertyBase;
import haxeon.ui.style.StyleProperty.StyleTransformProperty;

private class InheritedKeyCache {
	public var key:Null<String> = null;
	public function new() {}
}

/** Authoritative Haxe-side result of style resolution. Values remain in their typed declarations. */
class ComputedStyle {
	var values:Array<StyleValue>;
	var sources:Array<Null<StyleSource>>;
	internal var matchingRules(default, null):Array<StyleSource>;
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
	internal function setDeclaration(value:StyleValue, source:Null<StyleSource>):Void {
		if (value == null) throw "Computed styles require a declaration";
		ensureWritable();
		var property = value.property;
		if (property.inherited) inheritedKeyCache = null;
		var slot = property.slot;
		if (slot >= values.length) {
			values.resize(slot + 1);
			sources.resize(slot + 1);
		}
		values[slot] = value;
		sources[slot] = source;
	}

	internal function setColor(property:StyleColorProperty, value:Color, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.color(property, value), source);
	internal function setInsets(property:StyleInsetsProperty, value:Insets, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.insets(property, value), source);
	internal function setAxis(property:StyleAxisProperty, value:LayoutAxis, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.axis(property, value), source);
	internal function setMatrix(property:StyleTransformProperty, value:Transform2D, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.matrix(property, value), source);
	internal function setNumber(property:StyleProperty<Float>, value:Float, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.number(property, value), source);
	internal function setInteger(property:StyleProperty<Int>, value:Int, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.integer(property, value), source);
	internal function setBoolean(property:StyleProperty<Bool>, value:Bool, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.boolean(property, value), source);
	internal function setDecorations(value:DecorationChain, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.decorations(value), source);
	internal function setEffects(property:StyleProperty<EffectChain>, value:EffectChain, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.effectProperty(property, value), source);
	internal function setMask(value:Mask, source:Null<StyleSource>):Void
		setDeclaration(StyleValue.mask(value), source);

	inline function isSet(slot:Int):Bool return slot < values.length && values[slot] != null;
	inline function valueAt(slot:Int):Null<StyleValue> return slot < values.length ? values[slot] : null;
	inline function sourceAt(slot:Int):Null<StyleSource> return slot < sources.length ? sources[slot] : null;

	/** Whether a rule or the widget set `property`; otherwise its default applies. */
	public function has(property:StylePropertyBase):Bool return property != null && isSet(property.slot);

	/** Where the value of `property` came from, or null for the default. */
	public function source(property:StylePropertyBase):Null<StyleSource> return sourceAt(property.slot);
	/** Internal typed value access, including null-valued reference declarations. */
	@:allow(haxeon.ui.style.StyleResolver)
	function declaration(property:StylePropertyBase):Null<StyleValue> return valueAt(property.slot);

	/** The value of `property`. */
	public function getColor(property:StyleColorProperty):Color {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.colorOf(value);
	}

	/** The value of `property`. */
	public function getInsets(property:StyleInsetsProperty):Insets {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.insetsOf(value);
	}

	/** The value of `property`. */
	public function getAxis(property:StyleAxisProperty):LayoutAxis {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.axisOf(value);
	}

	/** The value of `property`. */
	public function getMatrix(property:StyleTransformProperty):Transform2D {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.matrixOf(value);
	}

	/** The value of `property`. */
	public function getNumber(property:StyleProperty<Float>):Float {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.numberOf(value);
	}

	/** The value of `property`. */
	public function getInteger(property:StyleProperty<Int>):Int {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.integerOf(value);
	}

	/** The value of `property`. */
	public function getBoolean(property:StyleProperty<Bool>):Bool {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.booleanOf(value);
	}

	/** The decorations. A copy, which the caller may change. */
	public function getDecorations():DecorationChain {
		var value = valueAt(StyleProperty.Decorations.slot);
		if (value == null) return StyleProperty.Decorations.defaultValue;
		var result = StyleValue.decorationsOf(value);
		return result == null ? null : result.copy();
	}

	/** The decorations. The stored value itself, without a copy: do not change it. */
	public function getDecorationsReadOnly():DecorationChain {
		var value = valueAt(StyleProperty.Decorations.slot);
		return value == null ? StyleProperty.Decorations.defaultValue : StyleValue.decorationsOf(value);
	}

	/** The effects of `property`. A copy, which the caller may change. */
	public function getEffects(property:StyleProperty<EffectChain>):EffectChain {
		var value = valueAt(property.slot);
		if (value == null) return property.defaultValue;
		var result = StyleValue.effectsOf(value);
		return result == null ? null : result.copy();
	}

	/** The effects of `property`. The stored value itself, without a copy: do not change it. */
	public function getEffectsReadOnly(property:StyleProperty<EffectChain>):EffectChain {
		var value = valueAt(property.slot);
		return value == null ? property.defaultValue : StyleValue.effectsOf(value);
	}

	/** The mask. A copy, which the caller may change. */
	public function getMask():Mask {
		var value = valueAt(StyleProperty.Mask.slot);
		if (value == null) return StyleProperty.Mask.defaultValue;
		var result = StyleValue.maskOf(value);
		return result == null ? null : result.copy();
	}

	/** The mask. The stored value itself, without a copy: do not change it. */
	public function getMaskReadOnly():Mask {
		var value = valueAt(StyleProperty.Mask.slot);
		return value == null ? StyleProperty.Mask.defaultValue : StyleValue.maskOf(value);
	}

	internal function sharesValuesWith(other:Null<ComputedStyle>):Bool return other != null && values == other.values;
	@:allow(haxeon.ui.style.StyleDiff)
	function sameValue(property:StylePropertyBase, other:ComputedStyle):Bool
		return values[property.slot].sameAs(other.values[property.slot]);

	internal function recordMatch(source:StyleSource):Void {
		if (source != null) {
			if (rulesShared) {
				matchingRules = matchingRules.copy();
				rulesShared = false;
			}
			matchingRules.push(source);
		}
	}

	/** The rules that matched, in the order they applied. */
	public function matchingStyleRules():Array<StyleSource> return matchingRules.copy();

	/** Every set value with its source, for inspection. */
	public function entries():Array<StyleInspectionEntry> {
		var result:Array<StyleInspectionEntry> = [];
		for (property in StyleProperty.all())
			if (isSet(property.slot)) result.push(new StyleInspectionEntry(property.name,
				values[property.slot].inspectForRead(), sourceAt(property.slot)));
		return result;
	}
	@:allow(haxeon.ui.core.UiInspector)
	function copyInspectionValues():Void {
		for (property in StyleProperty.all())
			if (property.copiedOnRead && isSet(property.slot)) values[property.slot].inspectForRead();
	}

	/** Materializes the resolved layout subset without mutating any input style. */
	public function toLayoutStyle(?base:LayoutStyle):LayoutStyle {
		var result = base == null ? new LayoutStyle() : base.copy();
		if (isSet(StyleProperty.Width.slot)) result.width = getAxis(StyleProperty.Width);
		if (isSet(StyleProperty.Height.slot)) result.height = getAxis(StyleProperty.Height);
		if (isSet(StyleProperty.Direction.slot)) result.direction =
			StyleValue.directionOf(values[StyleProperty.Direction.slot]);
		if (isSet(StyleProperty.ChildAlignX.slot)) result.childAlignX =
			StyleValue.alignmentXOf(values[StyleProperty.ChildAlignX.slot]);
		if (isSet(StyleProperty.ChildAlignY.slot)) result.childAlignY =
			StyleValue.alignmentYOf(values[StyleProperty.ChildAlignY.slot]);
		if (isSet(StyleProperty.ChildDistribution.slot)) result.childDistribution =
			StyleValue.distributionOf(values[StyleProperty.ChildDistribution.slot]);
		if (isSet(StyleProperty.Positioning.slot)) result.positioning =
			StyleValue.positioningOf(values[StyleProperty.Positioning.slot]);
		if (isSet(StyleProperty.AspectRatio.slot)) result.aspectRatio = getNumber(StyleProperty.AspectRatio);
		if (isSet(StyleProperty.WrapMode.slot)) result.wrapMode =
			StyleValue.wrapModeOf(values[StyleProperty.WrapMode.slot]);
		if (isSet(StyleProperty.RowGap.slot)) result.rowGap = getNumber(StyleProperty.RowGap);
		if (isSet(StyleProperty.ColumnGap.slot)) result.columnGap = getNumber(StyleProperty.ColumnGap);
		if (isSet(StyleProperty.AlignSelf.slot)) result.alignSelf =
			StyleValue.selfAlignmentOf(values[StyleProperty.AlignSelf.slot]);
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
		if (isSet(StyleProperty.RadiusBottomRight.slot)) result.radiusBottomRight =
			getNumber(StyleProperty.RadiusBottomRight);
		if (isSet(StyleProperty.RadiusBottomLeft.slot)) result.radiusBottomLeft =
			getNumber(StyleProperty.RadiusBottomLeft);
		if (isSet(StyleProperty.ClipHorizontal.slot)) result.clipHorizontal = getBoolean(StyleProperty.ClipHorizontal);
		if (isSet(StyleProperty.ClipVertical.slot)) result.clipVertical = getBoolean(StyleProperty.ClipVertical);
		if (isSet(StyleProperty.Visible.slot)) result.visible = getBoolean(StyleProperty.Visible);
		if (isSet(StyleProperty.Transform.slot)) result.transform = getMatrix(StyleProperty.Transform);
		if (isSet(StyleProperty.TransformOriginX.slot)) result.transformOriginX =
			getNumber(StyleProperty.TransformOriginX);
		if (isSet(StyleProperty.TransformOriginY.slot)) result.transformOriginY =
			getNumber(StyleProperty.TransformOriginY);
		return result;
	}

	/** An equal style, sharing storage until either changes. */
	public function copy():ComputedStyle {
		var result = new ComputedStyle();
		for (property in StyleProperty.all())
			if (isSet(property.slot)) result.setDeclaration(values[property.slot].copyForRead(),
				sourceAt(property.slot));
		for (source in matchingRules) result.recordMatch(source);
		return result;
	}
	internal function fork():ComputedStyle {
		if (inheritedKeyCache == null) inheritedKeyCache = new InheritedKeyCache();
		var result = new ComputedStyle(this);
		result.inheritedKeyCache = inheritedKeyCache;
		shared = true;
		rulesShared = true;
		return result;
	}
	internal function cachedInheritedKey():Null<String> return inheritedKeyCache == null ? null : inheritedKeyCache.key;
	internal function rememberInheritedKey(key:String):Void {
		if (inheritedKeyCache == null) inheritedKeyCache = new InheritedKeyCache();
		inheritedKeyCache.key = key;
	}
	function ensureWritable():Void {
		if (!shared) return;
		values = values.copy();
		sources = sources.copy();
		shared = false;
	}
}

/** Value-level difference between two computed styles, classified by impact. */
class StyleDiff {
	/** Whether any value differs. */
	public final changed:Bool;
	/** What the differences must redo. */
	public final impact:StyleImpact;

	/** A comparison's result. */
	public function new(changed:Bool, impact:StyleImpact) {
		this.changed = changed;
		this.impact = impact;
	}

	static final Unchanged = new StyleDiff(false, StyleImpact.None);
	/** Results are immutable and `impact` is a mask of six bits, so each distinct changed result is created once. */
	static final changedByImpact:Array<Null<StyleDiff>> = [for (_ in 0...64) null];

	static function changedWith(impact:StyleImpact):StyleDiff {
		var cached = changedByImpact[impact.rawValue];
		if (cached != null)
			return cached;
		var created = new StyleDiff(true, impact);
		changedByImpact[impact.rawValue] = created;
		return created;
	}

	/**
	 * Compares resolved values only. Provenance changes do not invalidate work
	 * when the resulting value is unchanged.
	 */
	public static function compare(previous:Null<ComputedStyle>, current:Null<ComputedStyle>):StyleDiff {
		if (previous == current || previous != null && previous.sharesValuesWith(current))
			return Unchanged;

		var changed = false;
		var impact:StyleImpact = StyleImpact.None;
		for (property in StyleProperty.all()) {
			var previousHas = previous != null && previous.has(property);
			var currentHas = current != null && current.has(property);
			if (previousHas == currentHas && (!previousHas || previous.sameValue(property, current)))
				continue;
			changed = true;
			impact |= property.impact;
		}
		return changed ? changedWith(impact) : Unchanged;
	}
}

/** Work categories affected by a resolved style property. */
enum abstract StyleImpact(Int) implements Flags {
	/** Nothing to redo. */
	var None = 0;
	/** Layout must run again. */
	var Layout = 1 << 0;
	/** Text must be shaped and wrapped again. */
	var TextLayout = 1 << 1;
	/** The box must be painted again. */
	var Paint = 1 << 2;
	/** Only compositing changes: opacity, transforms or effects. */
	var Composite = 1 << 3;
	/** The accessibility tree must be updated. */
	var Semantics = 1 << 4;
	/** Changes resolved visual geometry used by native picking without relayout. */
	var HitGeometry = 1 << 5;
}

/** Optional provenance attached to one computed property. */
class StyleSource {
	/** The name of the sheet the value came from. */
	public final stylesheet:String;
	/** The rule's selector, as text. */
	public final selector:String;
	/** The rule's place in its sheet, or -1 for values not from a sheet. */
	public final rule:Int;
	/** Which layer set it: "framework", "theme", "application", their "-state" rules, or "local". */
	public final layer:String;

	/** A value's origin. */
	public function new(stylesheet:String, selector:String, rule:Int, layer:String) {
		this.stylesheet = stylesheet == null ? "" : stylesheet;
		this.selector = selector == null ? "" : selector;
		this.rule = rule;
		this.layer = layer == null ? "" : layer;
	}

	/** A description for inspection. */
	public function toString():String
		return stylesheet + " " + selector + " (rule " + rule + ", " + layer + ")";
}

/** Inspectable computed property entry kept as a standalone Haxe module. */
class StyleInspectionEntry {
	/** The property's name. */
	public final name:String;
	/** Its value. */
	public final value:Dynamic;
	/** The rule that set it, or null for the default. */
	public final source:Null<StyleSource>;

	/** One inspected value. */
	public function new(name:String, value:Dynamic, source:Null<StyleSource>) {
		this.name = name;
		this.value = value;
		this.source = source;
	}

	/** Formats common typed values for headless logs and the interactive inspector. */
	public function describe():String {
		return switch name {
			case "background" | "borderColor" | "shadowColor" | "textColor" | "progressTrackColor"
				| "progressFillColor" | "sliderTrackColor" | "sliderFillColor" | "sliderThumbColor":
				var color:Null<Color> = cast value;
				color == null ? "null" : 'rgba(${color.red}, ${color.green}, ${color.blue}, ${color.alpha})';
			case "padding":
				var insets:Null<Insets> = cast value;
				insets == null ? "null" : '${insets.left}, ${insets.top}, ${insets.right}, ${insets.bottom}';
			case "width" | "height":
				var axis:Null<LayoutAxis> = cast value;
				axis == null ? "null" : Std.string(axis.sizing) + "(" + Std.string(axis.value) + ")";
			case "effects" | "backdropEffects":
				var effects:EffectChain = cast value;
				effects == null ? "null" : effects.toString();
			case "mask":
				var mask:Mask = cast value;
				mask == null ? "null" : mask.toString();
			default:
				Std.string(value);
		};
	}
}
