package haxeon.ui.style;

import haxeon.ui.widgets.layout.Padding;


import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAxis;
import haxeon.ui.Insets;
import haxeon.ui.Color;
import haxeon.ui.Transform2D;

/** One resolved property value and its optional cascade provenance. */
class ComputedProperty<T> {
	public final value:T;
	public final source:Null<StyleSource>;

	public function new(value:T, source:Null<StyleSource>) {
		this.value = value;
		this.source = source;
	}
}

private class InheritedKeyCache {
	public var key:Null<String> = null;
	public function new() {}
}

/** Authoritative Haxe-side result of style resolution. */
class ComputedStyle {
	/** Indexed by `StyleProperty.slot`: null is absent, and `NullValue` stands for a stored null. */
	var values:Array<Dynamic>;
	var sources:Array<Null<StyleSource>>;
	static final NullValue:Dynamic = new InheritedKeyCache();
	public var matchingRules(default, null):Array<StyleSource>;
	var shared:Bool;
	var inheritedKeyCache:Null<InheritedKeyCache>;

	public function new() {
		values = [];
		sources = [];
		matchingRules = [];
		shared = false;
		inheritedKeyCache = null;
	}

	public function set<T>(property:StyleProperty<T>, value:T, source:Null<StyleSource>):Void {
		if (property == null)
			throw "Computed styles require a property";
		ensureWritable();
		if (property.inherited)
			inheritedKeyCache = null;
		var slot = property.slot;
		if (slot >= values.length) {
			values.resize(slot + 1);
			sources.resize(slot + 1);
		}
		values[slot] = value == null ? NullValue : value;
		sources[slot] = source;
	}

	inline function isSet(slot:Int):Bool
		return slot < values.length && values[slot] != null;

	inline function valueAt(slot:Int):Dynamic {
		var value = slot < values.length ? values[slot] : null;
		return value == NullValue ? null : value;
	}

	inline function sourceAt(slot:Int):Null<StyleSource>
		return slot < sources.length ? sources[slot] : null;

	public function has<T>(property:StyleProperty<T>):Bool
		return property != null && isSet(property.slot);

	public function get<T>(property:StyleProperty<T>):T {
		if (property == null)
			throw "Computed styles require a property";
		var slot = property.slot;
		if (!isSet(slot))
			return property.defaultValue;
		var value = valueAt(slot);
		return property.copiedOnRead ? cast copyValue(cast property, value) : cast value;
	}

	/** Reads the effective value without copying it; callers must not mutate the result. */
	public function getReadOnly<T>(property:StyleProperty<T>):T {
		if (property == null) throw "Computed styles require a property";
		return isSet(property.slot) ? cast valueAt(property.slot) : property.defaultValue;
	}

	/** True when both styles read the same value storage (cache forks do until one mutates), so no value can differ. */
	public function sharesValuesWith(other:Null<ComputedStyle>):Bool
		return other != null && values == other.values;

	/** Reads a value without the defensive copy `get` makes; the caller must not mutate it. */
	public function peek<T>(property:StyleProperty<T>):T
		return cast valueAt(property.slot);

	public function property<T>(property:StyleProperty<T>):ComputedProperty<T>
		return new ComputedProperty(get(property), sourceAt(property.slot));

	public function source<T>(property:StyleProperty<T>):Null<StyleSource>
		return sourceAt(property.slot);

	/** Records every matching rule, including rules whose declarations were overridden. */
	public function recordMatch(source:StyleSource):Void {
		if (source != null) {
			ensureWritable();
			matchingRules.push(source);
		}
	}

	/** Returns a stable copy for inspectors and external tooling. */
	public function matchingStyleRules():Array<StyleSource>
		return matchingRules.copy();

	public function entries():Array<StyleInspectionEntry> {
		var result:Array<StyleInspectionEntry> = [];
		for (property in StyleProperty.all())
			if (isSet(property.slot))
				result.push(new StyleInspectionEntry(property.name, copyValue(property, valueAt(property.slot)),
					sourceAt(property.slot)));
		return result;
	}

	/** Materializes the resolved layout subset without mutating any input style. */
	public function toLayoutStyle(?base:LayoutStyle):LayoutStyle {
		var result = base == null ? new LayoutStyle() : base.copy();
		if (isSet(StyleProperty.Width.slot)) {
			var width:LayoutAxis = cast valueAt(StyleProperty.Width.slot);
			result.width = width;
		}
		if (isSet(StyleProperty.Height.slot)) {
			var height:LayoutAxis = cast valueAt(StyleProperty.Height.slot);
			result.height = height;
		}
		if (isSet(StyleProperty.Direction.slot)) result.direction = cast valueAt(StyleProperty.Direction.slot);
		if (isSet(StyleProperty.ChildAlignX.slot)) result.childAlignX = cast valueAt(StyleProperty.ChildAlignX.slot);
		if (isSet(StyleProperty.ChildAlignY.slot)) result.childAlignY = cast valueAt(StyleProperty.ChildAlignY.slot);
		if (isSet(StyleProperty.ChildDistribution.slot)) result.childDistribution = cast valueAt(StyleProperty.ChildDistribution.slot);
		if (isSet(StyleProperty.Positioning.slot)) result.positioning = cast valueAt(StyleProperty.Positioning.slot);
		if (isSet(StyleProperty.AspectRatio.slot)) result.aspectRatio = cast valueAt(StyleProperty.AspectRatio.slot);
		if (isSet(StyleProperty.WrapMode.slot)) result.wrapMode = cast valueAt(StyleProperty.WrapMode.slot);
		if (isSet(StyleProperty.RowGap.slot)) result.rowGap = cast valueAt(StyleProperty.RowGap.slot);
		if (isSet(StyleProperty.ColumnGap.slot)) result.columnGap = cast valueAt(StyleProperty.ColumnGap.slot);
		if (isSet(StyleProperty.AlignSelf.slot)) result.alignSelf = cast valueAt(StyleProperty.AlignSelf.slot);
		if (isSet(StyleProperty.PositionX.slot)) result.positionX = cast valueAt(StyleProperty.PositionX.slot);
		if (isSet(StyleProperty.PositionY.slot)) result.positionY = cast valueAt(StyleProperty.PositionY.slot);
		if (isSet(StyleProperty.ZIndex.slot)) result.zIndex = cast valueAt(StyleProperty.ZIndex.slot);
		if (isSet(StyleProperty.ClipToParent.slot)) result.clipToParent = cast valueAt(StyleProperty.ClipToParent.slot);
		if (isSet(StyleProperty.Padding.slot)) {
			var padding:Insets = cast valueAt(StyleProperty.Padding.slot);
			result.padding = padding;
		}
		if (isSet(StyleProperty.ChildGap.slot)) result.childGap = cast valueAt(StyleProperty.ChildGap.slot);
		if (isSet(StyleProperty.Background.slot)) {
			var background:Color = cast valueAt(StyleProperty.Background.slot);
			result.background = background;
		}
		if (isSet(StyleProperty.RadiusTopLeft.slot)) result.radiusTopLeft = cast valueAt(StyleProperty.RadiusTopLeft.slot);
		if (isSet(StyleProperty.RadiusTopRight.slot)) result.radiusTopRight = cast valueAt(StyleProperty.RadiusTopRight.slot);
		if (isSet(StyleProperty.RadiusBottomRight.slot)) result.radiusBottomRight = cast valueAt(StyleProperty.RadiusBottomRight.slot);
		if (isSet(StyleProperty.RadiusBottomLeft.slot)) result.radiusBottomLeft = cast valueAt(StyleProperty.RadiusBottomLeft.slot);
		if (isSet(StyleProperty.ClipHorizontal.slot)) result.clipHorizontal = cast valueAt(StyleProperty.ClipHorizontal.slot);
		if (isSet(StyleProperty.ClipVertical.slot)) result.clipVertical = cast valueAt(StyleProperty.ClipVertical.slot);
		if (isSet(StyleProperty.Visible.slot)) result.visible = cast valueAt(StyleProperty.Visible.slot);
		if (isSet(StyleProperty.Transform.slot)) {
			var transform:Transform2D = cast valueAt(StyleProperty.Transform.slot);
			result.transform = transform;
		}
		if (isSet(StyleProperty.TransformOriginX.slot))
			result.transformOriginX = cast valueAt(StyleProperty.TransformOriginX.slot);
		if (isSet(StyleProperty.TransformOriginY.slot))
			result.transformOriginY = cast valueAt(StyleProperty.TransformOriginY.slot);
		return result;
	}

	public function copy():ComputedStyle {
		var result = new ComputedStyle();
		for (property in StyleProperty.all())
			if (isSet(property.slot))
				result.set(property, copyValue(property, valueAt(property.slot)), sourceAt(property.slot));
		for (source in matchingRules)
			result.recordMatch(source);
		return result;
	}

	/** Fast copy used by style caches; map storage is detached only on mutation. */
	public function fork():ComputedStyle {
		var result = new ComputedStyle();
		if (inheritedKeyCache == null)
			inheritedKeyCache = new InheritedKeyCache();
		result.inheritedKeyCache = inheritedKeyCache;
		result.values = values;
		result.sources = sources;
		result.matchingRules = matchingRules.copy();
		shared = true;
		result.shared = true;
		return result;
	}

	/** Shared across style-cache forks; set() detaches it before mutation. */
	public function cachedInheritedKey():Null<String>
		return inheritedKeyCache == null ? null : inheritedKeyCache.key;

	public function rememberInheritedKey(key:String):Void {
		if (inheritedKeyCache == null)
			inheritedKeyCache = new InheritedKeyCache();
		inheritedKeyCache.key = key;
	}

	function ensureWritable():Void {
		if (!shared)
			return;
		values = values.copy();
		sources = sources.copy();
		shared = false;
	}

	/** Copies the mutable value objects that can be exposed through a computed style; Insets and Transform2D are immutable. */
	static function copyValue(property:StyleProperty<Dynamic>, value:Dynamic):Dynamic {
		if (value == null)
			return null;
		if (!property.copiedOnRead)
			return value;
		return switch property.name {
			case "effects" | "backdropEffects":
				var effects:EffectChain = cast value;
				effects == null ? null : effects.copy();
			case "decorations":
				var decorations:DecorationChain = cast value;
				decorations == null ? null : decorations.copy();
			case "mask":
				var mask:Mask = cast value;
				mask == null ? null : mask.copy();
			default:
				value;
		};
	}
}
