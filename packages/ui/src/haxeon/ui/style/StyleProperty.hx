package haxeon.ui.style;

import haxeon.ui.Paint;
import haxeon.ui.TextLayout;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;

import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.Decoration;
/** Metadata shared by typed style properties. */
class StylePropertyBase {
	/** The property's name, as the inspector shows it. */
	public final name:String;
	/** Dense index among all properties, so a computed style stores its values in arrays instead of hashing names. */
	public final slot:Int;
	/** Values of this property are mutable objects that a computed style hands out as copies. */
	public final copiedOnRead:Bool;

	/** Whether a box takes its parent's value when no rule sets it. */
	public final inherited:Bool;

	/** What a change of the value must redo: layout, text layout, paint or compositing. */
	public final impact:StyleImpact;

	/** Whether transitions can animate the value; otherwise it switches at once. */
	public var hasInterpolation(default, null):Bool;

	internal function new(name:String, slot:Int, inherited:Bool, impact:StyleImpact) {
		this.name = name;
		this.slot = slot;
		this.copiedOnRead = name == "effects" || name == "backdropEffects" || name == "decorations" || name == "mask";
		this.inherited = inherited;
		this.impact = impact;
		this.hasInterpolation = false;
	}
}

/** Metadata and layout bridge for one typed style property. */
class StyleProperty<T> extends StylePropertyBase {
	static var nextSlot:Int = 0;

	/** The value when no rule sets the property. */
	public final defaultValue:T;

	/**
	 * A property named `name`; `inherited` properties take the parent's value when not set, and `impact` says what a
	 * change must redo.
	 */
	public function new(name:String, defaultValue:T, inherited:Bool, impact:StyleImpact) {
		super(name, allocateSlot(name), inherited, impact);
		this.defaultValue = defaultValue;
	}

	internal static function allocateSlot(name:String):Int {
		if (name == null || name.length == 0)
			throw "Style properties require a name";
		return nextSlot++;
	}

	/** How many slots exist so far; every property created later gets a higher one. */
	public static function slotCount():Int
		return nextSlot;

	static function floatInterpolate(left:Float, right:Float, amount:Float):Float
		return left + (right - left) * amount;

	static function colorInterpolate(left:Color, right:Color, amount:Float):Color
		return Color.rgba(left.red + (right.red - left.red) * amount,
			left.green + (right.green - left.green) * amount,
			left.blue + (right.blue - left.blue) * amount,
			left.alpha + (right.alpha - left.alpha) * amount);

	/** The box's width: fixed, fit to content, grow, or a percentage. Fits by default. */
	public static final Width:StyleAxisProperty = new StyleAxisProperty("width", LayoutAxis.fit(), false,
		StyleImpact.Layout);

	/** The box's height: fixed, fit to content, grow, or a percentage. Fits by default. */
	public static final Height:StyleAxisProperty = new StyleAxisProperty("height", LayoutAxis.fit(), false,
		StyleImpact.Layout);

	/** Whether children are laid out top to bottom (the default) or left to right. */
	public static final Direction:StyleProperty<LayoutDirection> = new StyleProperty("direction",
		LayoutDirection.TopToBottom, false, StyleImpact.Layout);

	/** Where children sit horizontally within the box. Start by default. */
	public static final ChildAlignX:StyleProperty<LayoutAlignmentX> = new StyleProperty("childAlignX",
		LayoutAlignmentX.Start, false, StyleImpact.Layout);

	/** Where children sit vertically within the box. Start by default. */
	public static final ChildAlignY:StyleProperty<LayoutAlignmentY> = new StyleProperty("childAlignY",
		LayoutAlignmentY.Start, false, StyleImpact.Layout);

	/** How spare space along the main axis is shared between children. Start by default. */
	public static final ChildDistribution:StyleProperty<LayoutDistribution> = new StyleProperty("childDistribution",
		LayoutDistribution.Start, false, StyleImpact.Layout);

	/**
	 * Whether the box flows with its siblings (the default) or is placed at `PositionX`, `PositionY` within its
	 * parent.
	 */
	public static final Positioning:StyleProperty<LayoutPositioning> = new StyleProperty("positioning",
		LayoutPositioning.Flow, false, StyleImpact.Layout);

	/** Width over height the box keeps; 0, the default, keeps none. */
	public static final AspectRatio:StyleProperty<Float> = new StyleProperty("aspectRatio", 0.0, false,
		StyleImpact.Layout);

	/** Whether children wrap onto further lines when they overflow. No wrapping by default. */
	public static final WrapMode:StyleProperty<LayoutWrapMode> = new StyleProperty("wrapMode", LayoutWrapMode.NoWrap,
		false, StyleImpact.Layout);

	/** Space between wrapped lines, in logical pixels. */
	public static final RowGap:StyleProperty<Float> = new StyleProperty("rowGap", 0.0, false, StyleImpact.Layout);

	/** Space between children on a wrapped line, in logical pixels. */
	public static final ColumnGap:StyleProperty<Float> = new StyleProperty("columnGap", 0.0, false, StyleImpact.Layout);

	/** Overrides the parent's cross-axis alignment for this box; inherits it by default. */
	public static final AlignSelf:StyleProperty<LayoutSelfAlignment> = new StyleProperty("alignSelf",
		LayoutSelfAlignment.Inherit, false, StyleImpact.Layout);

	/** The left edge of a placed box, within its parent. */
	public static final PositionX:StyleProperty<Float> = new StyleProperty("positionX", 0.0, false, StyleImpact.Layout);

	/** The top edge of a placed box, within its parent. */
	public static final PositionY:StyleProperty<Float> = new StyleProperty("positionY", 0.0, false, StyleImpact.Layout);

	/** Stacking order among siblings: higher draws on top and takes the pointer first. */
	public static final ZIndex:StyleProperty<Int> = new StyleProperty("zIndex", 0, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** Whether the box paints above ordinary content, within the nearest enclosing overlay; needs absolute positioning. */
	public static final Overlay:StyleProperty<Bool> = new StyleProperty("overlay", false, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** Whether the parent's clip applies to the box. True by default. */
	public static final ClipToParent:StyleProperty<Bool> = new StyleProperty("clipToParent", true, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** Space between the box's edges and its children. */
	public static final Padding:StyleInsetsProperty = new StyleInsetsProperty("padding", new Insets(0.0, 0.0, 0.0, 0.0),
		false, StyleImpact.Layout);

	/** Space between consecutive children, in logical pixels. */
	public static final ChildGap:StyleProperty<Float> = new StyleProperty("childGap", 0.0, false, StyleImpact.Layout);

	/** The box's fill. Transparent by default. */
	public static final Background:StyleColorProperty = new StyleColorProperty("background",
		Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);

	/** The top-left corner radius. */
	public static final RadiusTopLeft:StyleProperty<Float> = new StyleInterpolatedProperty("radiusTopLeft", 0.0, false,
		StyleImpact.Paint, floatInterpolate);

	/** The top-right corner radius. */
	public static final RadiusTopRight:StyleProperty<Float> = new StyleInterpolatedProperty("radiusTopRight", 0.0,
		false, StyleImpact.Paint, floatInterpolate);

	/** The bottom-right corner radius. */
	public static final RadiusBottomRight:StyleProperty<Float> = new StyleInterpolatedProperty("radiusBottomRight", 0.0,
		false, StyleImpact.Paint, floatInterpolate);

	/** The bottom-left corner radius. */
	public static final RadiusBottomLeft:StyleProperty<Float> = new StyleInterpolatedProperty("radiusBottomLeft", 0.0,
		false, StyleImpact.Paint, floatInterpolate);

	/** Whether children are clipped at the box's left and right edges. */
	public static final ClipHorizontal:StyleProperty<Bool> = new StyleProperty("clipHorizontal", false, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** Whether children are clipped at the box's top and bottom edges. */
	public static final ClipVertical:StyleProperty<Bool> = new StyleProperty("clipVertical", false, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** Whether the box and its children are drawn and hit tested; hidden, it still takes its place in layout. True by default. */
	public static final Visible:StyleProperty<Bool> = new StyleProperty("visible", true, false,
		StyleImpact.Paint | StyleImpact.HitGeometry);

	/** A 2D transform applied when compositing, around the transform origin; layout is unaffected. */
	public static final Transform:StyleTransformProperty = new StyleTransformProperty("transform",
		Transform2D.identity(), false, StyleImpact.Composite | StyleImpact.HitGeometry);

	/** The transform origin's horizontal position, as a fraction of the width. 0.5 by default. */
	public static final TransformOriginX:StyleProperty<Float> = new StyleInterpolatedProperty("transformOriginX", 0.5,
		false, StyleImpact.Composite | StyleImpact.HitGeometry, floatInterpolate);

	/** The transform origin's vertical position, as a fraction of the height. 0.5 by default. */
	public static final TransformOriginY:StyleProperty<Float> = new StyleInterpolatedProperty("transformOriginY", 0.5,
		false, StyleImpact.Composite | StyleImpact.HitGeometry, floatInterpolate);

	/** The border's color. */
	public static final BorderColor:StyleColorProperty = new StyleColorProperty("borderColor",
		Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);

	/** The border's width, in logical pixels; 0 draws none. */
	public static final BorderWidth:StyleProperty<Float> = new StyleInterpolatedProperty("borderWidth", 0.0, false,
		StyleImpact.Paint, floatInterpolate);
	/** The box shadow's color; transparent draws none. */
	public static final ShadowColor:StyleColorProperty = new StyleColorProperty("shadowColor",
		Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);

	/** How far the shadow is moved right. */
	public static final ShadowOffsetX:StyleProperty<Float> = new StyleInterpolatedProperty("shadowOffsetX", 0.0, false,
		StyleImpact.Paint, floatInterpolate);

	/** How far the shadow is moved down. */
	public static final ShadowOffsetY:StyleProperty<Float> = new StyleInterpolatedProperty("shadowOffsetY", 0.0, false,
		StyleImpact.Paint, floatInterpolate);
	/** UI-facing blur radius. The native renderer converts it to Gaussian sigma. */
	public static final ShadowBlur:StyleProperty<Float> = new StyleInterpolatedProperty("shadowBlur", 0.0, false,
		StyleImpact.Paint, floatInterpolate);

	/** How far the shadow grows beyond the box before blurring. */
	public static final ShadowSpread:StyleProperty<Float> = new StyleInterpolatedProperty("shadowSpread", 0.0, false,
		StyleImpact.Paint, floatInterpolate);
	/** Ordered post-layout geometry and image decorations. */
	public static final Decorations:StyleProperty<DecorationChain> = new StyleInterpolatedProperty("decorations",
		DecorationChain.empty(), false, StyleImpact.Paint,
		DecorationChain.interpolate);

	/** How opaque the box and its children are, from 0 to 1, applied as one layer. */
	public static final Opacity:StyleProperty<Float> = new StyleInterpolatedProperty("opacity", 1.0, false,
		StyleImpact.Composite, floatInterpolate);
	/** Ordered post-layout filters applied to this node and its descendants. */
	public static final Effects:StyleProperty<EffectChain> = new StyleInterpolatedProperty("effects",
		EffectChain.empty(), false, StyleImpact.Composite,
		EffectChain.interpolate);
	/** Ordered filters applied to the already-rendered backdrop behind this node. */
	public static final BackdropEffects:StyleProperty<EffectChain> = new StyleInterpolatedProperty("backdropEffects",
		EffectChain.empty(), false, StyleImpact.Composite,
		EffectChain.interpolate);
	/** Source-alpha mask applied during isolated-layer composition. */
	public static final Mask:StyleProperty<Mask> = new StyleProperty<Mask>("mask", null, false, StyleImpact.Composite);
	/** Paint inputs used by the retained custom progress renderer. */
	public static final ProgressTrackColor:StyleColorProperty = new StyleColorProperty("progressTrackColor",
		Color.rgba(0.19, 0.21, 0.25, 1.0), false,
		StyleImpact.Paint, colorInterpolate);

	/** The filled part of a progress bar. */
	public static final ProgressFillColor:StyleColorProperty = new StyleColorProperty("progressFillColor",
		Color.rgba(0.22, 0.52, 0.84, 1.0), false,
		StyleImpact.Paint, colorInterpolate);
	/** Paint inputs used by the retained custom slider renderer. */
	public static final SliderTrackColor:StyleColorProperty = new StyleColorProperty("sliderTrackColor",
		Color.rgba(0.16, 0.18, 0.22, 1.0), false,
		StyleImpact.Paint, colorInterpolate);

	/** The part of a slider's track before the thumb. */
	public static final SliderFillColor:StyleColorProperty = new StyleColorProperty("sliderFillColor",
		Color.rgba(0.22, 0.48, 0.86, 1.0), false,
		StyleImpact.Paint, colorInterpolate);

	/** A slider's thumb. */
	public static final SliderThumbColor:StyleColorProperty = new StyleColorProperty("sliderThumbColor",
		Color.rgba(0.96, 0.97, 0.99, 1.0), false,
		StyleImpact.Paint, colorInterpolate);

	/** Inherited typography/paint inputs are computed here and applied by text widgets. */
	public static final TextColor:StyleColorProperty = new StyleColorProperty("textColor",
		Color.rgba(1.0, 1.0, 1.0, 1.0), true, StyleImpact.Paint);

	/** The text size, in logical pixels; inherited. */
	public static final FontSize:StyleProperty<Float> = new StyleProperty("fontSize", 16.0, true,
		StyleImpact.Layout | StyleImpact.TextLayout | StyleImpact.Paint);

	/** Extra space between letters, in logical pixels; inherited. */
	public static final LetterSpacing:StyleProperty<Float> = new StyleProperty("letterSpacing", 0.0, true,
		StyleImpact.TextLayout | StyleImpact.Paint);

	static var definitions:Array<StylePropertyBase>;

	static function baseProperty(property:StylePropertyBase):StylePropertyBase
		return property;

	/** Stable registry used by default construction, local-style projection, and inspection. */
	public static function all():Array<StylePropertyBase> {
		if (definitions == null)
			definitions = [
				baseProperty(Width), baseProperty(Height), baseProperty(Direction),
				baseProperty(ChildAlignX), baseProperty(ChildAlignY), baseProperty(ChildDistribution),
				baseProperty(Positioning), baseProperty(AspectRatio), baseProperty(WrapMode),
				baseProperty(RowGap), baseProperty(ColumnGap), baseProperty(AlignSelf),
				baseProperty(PositionX), baseProperty(PositionY), baseProperty(ZIndex),
				baseProperty(Overlay), baseProperty(ClipToParent), baseProperty(Padding), baseProperty(ChildGap),
				baseProperty(Background), baseProperty(RadiusTopLeft), baseProperty(RadiusTopRight),
				baseProperty(RadiusBottomRight), baseProperty(RadiusBottomLeft),
				baseProperty(ClipHorizontal), baseProperty(ClipVertical), baseProperty(Visible),
				baseProperty(Transform), baseProperty(TransformOriginX), baseProperty(TransformOriginY),
				baseProperty(TextColor), baseProperty(FontSize),
				baseProperty(LetterSpacing), baseProperty(BorderColor), baseProperty(BorderWidth),
				baseProperty(ShadowColor),
				baseProperty(ShadowOffsetX), baseProperty(ShadowOffsetY), baseProperty(ShadowBlur),
				baseProperty(ShadowSpread),
				baseProperty(Decorations),
				baseProperty(Opacity), baseProperty(Effects), baseProperty(BackdropEffects),
				baseProperty(StyleProperty.Mask),
				baseProperty(ProgressTrackColor), baseProperty(ProgressFillColor),
				baseProperty(SliderTrackColor), baseProperty(SliderFillColor),
				baseProperty(SliderThumbColor)
			];
		return definitions;
	}
}

/** Interpolation is an explicit capability; discrete properties carry no function signature. */
class StyleInterpolatedProperty<T> extends StyleProperty<T> {
	/** Blends two values, for transitions. */
	public final interpolate:T->T->Float->T;

	/** A property that transitions can animate, blending with `interpolate`. */
	public function new(name:String, defaultValue:T, inherited:Bool, impact:StyleImpact,
			interpolate:T->T->Float->T) {
		if (interpolate == null) throw "An interpolated style property requires an interpolator";
		super(name, defaultValue, inherited, impact);
		this.interpolate = interpolate;
		hasInterpolation = true;
	}

}

/** A property holding a `Color`, such as `Background`; transitions can animate it. */
class StyleColorProperty extends StylePropertyBase {
	/** The value when no rule sets the property. */
	public final defaultValue:Color;
	final colorEqual:Null<Color->Color->Bool>;
	final colorInterpolate:Null<Color->Color->Float->Color>;

	/** A color property; see `StyleProperty.new`. */
	public function new(name:String, defaultValue:Color, inherited:Bool, impact:StyleImpact,
			?interpolate:Color->Color->Float->Color, ?equalValue:Color->Color->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact);
		this.defaultValue = defaultValue;
		colorEqual = equalValue;
		colorInterpolate = interpolate;
		hasInterpolation = interpolate != null;
	}

	/** Whether two values are equal. */
	public function sameColor(left:Color, right:Color):Bool
		return colorEqual == null ? haxeon.Equality.equals(left, right) : colorEqual(left, right);

	/** The color `amount` of the way from `left` to `right`. */
	public function interpolateColor(left:Color, right:Color, amount:Float):Color {
		if (colorInterpolate == null) throw "Style property does not support interpolation";
		return colorInterpolate(left, right, amount);
	}
}

/** A property holding `Insets`, such as `Padding`. */
class StyleInsetsProperty extends StylePropertyBase {
	/** The value when no rule sets the property. */
	public final defaultValue:Insets;
	final insetsEqual:Null<Insets->Insets->Bool>;

	/** An insets property; see `StyleProperty.new`. */
	public function new(name:String, defaultValue:Insets, inherited:Bool, impact:StyleImpact,
			?equalValue:Insets->Insets->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact);
		this.defaultValue = defaultValue;
		insetsEqual = equalValue;
	}

	/** Whether two values are equal. */
	public function sameInsets(left:Insets, right:Insets):Bool
		return insetsEqual == null ? haxeon.Equality.equals(left, right) : insetsEqual(left, right);
}

/** A property holding a `LayoutAxis`, such as `Width`. */
class StyleAxisProperty extends StylePropertyBase {
	/** The value when no rule sets the property. */
	public final defaultValue:LayoutAxis;
	final axisEqual:Null<LayoutAxis->LayoutAxis->Bool>;

	/** A sizing property; see `StyleProperty.new`. */
	public function new(name:String, defaultValue:LayoutAxis, inherited:Bool, impact:StyleImpact,
			?equalValue:LayoutAxis->LayoutAxis->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact);
		this.defaultValue = defaultValue;
		axisEqual = equalValue;
	}

	/** Whether two values are equal. */
	public function sameAxis(left:LayoutAxis, right:LayoutAxis):Bool
		return axisEqual == null ? haxeon.Equality.equals(left, right) : axisEqual(left, right);
}

/** A property holding a `Transform2D`, such as `Transform`. */
class StyleTransformProperty extends StylePropertyBase {
	/** The value when no rule sets the property. */
	public final defaultValue:Transform2D;
	final transformEqual:Null<Transform2D->Transform2D->Bool>;

	/** A transform property; see `StyleProperty.new`. */
	public function new(name:String, defaultValue:Transform2D, inherited:Bool, impact:StyleImpact,
			?equalValue:Transform2D->Transform2D->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact);
		this.defaultValue = defaultValue;
		transformEqual = equalValue;
	}

	/** Whether two values are equal. */
	public function sameTransform(left:Transform2D, right:Transform2D):Bool
		return transformEqual == null ? haxeon.Equality.equals(left, right) : transformEqual(left, right);
}
