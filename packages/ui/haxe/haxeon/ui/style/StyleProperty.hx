package haxeon.ui.style;

import haxeon.ui.Paint;
import haxeon.ui.TextLayout;

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

/** Metadata shared by typed style properties. */
class StylePropertyBase {
	public final name:String;
	/** Dense index among all properties, so a computed style stores its values in arrays instead of hashing names. */
	public final slot:Int;
	/** Values of this property are mutable objects that a computed style hands out as copies. */
	public final copiedOnRead:Bool;
	public final inherited:Bool;
	public final impact:StyleImpact;
	public final hasInterpolation:Bool;

	public function new(name:String, slot:Int, inherited:Bool, impact:StyleImpact, hasInterpolation:Bool) {
		this.name = name;
		this.slot = slot;
		this.copiedOnRead = name == "effects" || name == "backdropEffects" || name == "decorations" || name == "mask";
		this.inherited = inherited;
		this.impact = impact;
		this.hasInterpolation = hasInterpolation;
	}
}

/** Metadata and layout bridge for one typed style property. */
class StyleProperty<T> extends StylePropertyBase {
	static var nextSlot:Int = 0;
	public final defaultValue:T;
	public final interpolate:Null<T->T->Float->T>;

	public function new(name:String, defaultValue:T, inherited:Bool, impact:StyleImpact,
			?interpolate:T->T->Float->T) {
		super(name, allocateSlot(name), inherited, impact, interpolate != null);
		this.defaultValue = defaultValue;
		this.interpolate = interpolate;
	}

	public static function allocateSlot(name:String):Int {
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

	public static final Width:StyleAxisProperty = new StyleAxisProperty(
		"width", LayoutAxis.fit(), false, StyleImpact.Layout);
	public static final Height:StyleAxisProperty = new StyleAxisProperty(
		"height", LayoutAxis.fit(), false, StyleImpact.Layout);
	public static final Direction:StyleProperty<LayoutDirection> = new StyleProperty(
		"direction", LayoutDirection.TopToBottom, false, StyleImpact.Layout, null);
	public static final ChildAlignX:StyleProperty<LayoutAlignmentX> = new StyleProperty(
		"childAlignX", LayoutAlignmentX.Start, false, StyleImpact.Layout, null);
	public static final ChildAlignY:StyleProperty<LayoutAlignmentY> = new StyleProperty(
		"childAlignY", LayoutAlignmentY.Start, false, StyleImpact.Layout, null);
	public static final ChildDistribution:StyleProperty<LayoutDistribution> = new StyleProperty(
		"childDistribution", LayoutDistribution.Start, false, StyleImpact.Layout, null);
	public static final Positioning:StyleProperty<LayoutPositioning> = new StyleProperty(
		"positioning", LayoutPositioning.Flow, false, StyleImpact.Layout, null);
	public static final AspectRatio:StyleProperty<Float> = new StyleProperty(
		"aspectRatio", 0.0, false, StyleImpact.Layout, null);
	public static final WrapMode:StyleProperty<LayoutWrapMode> = new StyleProperty(
		"wrapMode", LayoutWrapMode.NoWrap, false, StyleImpact.Layout, null);
	public static final RowGap:StyleProperty<Float> = new StyleProperty(
		"rowGap", 0.0, false, StyleImpact.Layout, null);
	public static final ColumnGap:StyleProperty<Float> = new StyleProperty(
		"columnGap", 0.0, false, StyleImpact.Layout, null);
	public static final AlignSelf:StyleProperty<LayoutSelfAlignment> = new StyleProperty(
		"alignSelf", LayoutSelfAlignment.Inherit, false, StyleImpact.Layout, null);
	public static final PositionX:StyleProperty<Float> = new StyleProperty(
		"positionX", 0.0, false, StyleImpact.Layout, null);
	public static final PositionY:StyleProperty<Float> = new StyleProperty(
		"positionY", 0.0, false, StyleImpact.Layout, null);
	public static final ZIndex:StyleProperty<Int> = new StyleProperty(
		"zIndex", 0, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final Overlay:StyleProperty<Bool> = new StyleProperty(
		"overlay", false, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final ClipToParent:StyleProperty<Bool> = new StyleProperty(
		"clipToParent", true, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final Padding:StyleInsetsProperty = new StyleInsetsProperty(
		"padding", new Insets(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Layout);
	public static final ChildGap:StyleProperty<Float> = new StyleProperty(
		"childGap", 0.0, false, StyleImpact.Layout, null);
	public static final Background:StyleColorProperty = new StyleColorProperty(
		"background", Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);
	public static final RadiusTopLeft:StyleProperty<Float> = new StyleProperty(
		"radiusTopLeft", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final RadiusTopRight:StyleProperty<Float> = new StyleProperty(
		"radiusTopRight", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final RadiusBottomRight:StyleProperty<Float> = new StyleProperty(
		"radiusBottomRight", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final RadiusBottomLeft:StyleProperty<Float> = new StyleProperty(
		"radiusBottomLeft", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final ClipHorizontal:StyleProperty<Bool> = new StyleProperty(
		"clipHorizontal", false, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final ClipVertical:StyleProperty<Bool> = new StyleProperty(
		"clipVertical", false, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final Visible:StyleProperty<Bool> = new StyleProperty(
		"visible", true, false, StyleImpact.Paint | StyleImpact.HitGeometry, null);
	public static final Transform:StyleTransformProperty = new StyleTransformProperty(
		"transform", Transform2D.identity(), false, StyleImpact.Composite | StyleImpact.HitGeometry);
	public static final TransformOriginX:StyleProperty<Float> = new StyleProperty(
		"transformOriginX", 0.5, false, StyleImpact.Composite | StyleImpact.HitGeometry, floatInterpolate);
	public static final TransformOriginY:StyleProperty<Float> = new StyleProperty(
		"transformOriginY", 0.5, false, StyleImpact.Composite | StyleImpact.HitGeometry, floatInterpolate);
	public static final BorderColor:StyleColorProperty = new StyleColorProperty(
		"borderColor", Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);
	public static final BorderWidth:StyleProperty<Float> = new StyleProperty(
		"borderWidth", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final OutlineColor:StyleColorProperty = new StyleColorProperty(
		"outlineColor", Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);
	public static final OutlineWidth:StyleProperty<Float> = new StyleProperty(
		"outlineWidth", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final ShadowColor:StyleColorProperty = new StyleColorProperty(
		"shadowColor", Color.rgba(0.0, 0.0, 0.0, 0.0), false, StyleImpact.Paint, colorInterpolate);
	public static final ShadowOffsetX:StyleProperty<Float> = new StyleProperty(
		"shadowOffsetX", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final ShadowOffsetY:StyleProperty<Float> = new StyleProperty(
		"shadowOffsetY", 0.0, false, StyleImpact.Paint, floatInterpolate);
	/** UI-facing blur radius. The native renderer converts it to Gaussian sigma. */
	public static final ShadowBlur:StyleProperty<Float> = new StyleProperty(
		"shadowBlur", 0.0, false, StyleImpact.Paint, floatInterpolate);
	public static final ShadowSpread:StyleProperty<Float> = new StyleProperty(
		"shadowSpread", 0.0, false, StyleImpact.Paint, floatInterpolate);
	/** Ordered post-layout geometry and image decorations. */
	public static final Decorations:StyleProperty<DecorationChain> = new StyleProperty(
		"decorations", DecorationChain.empty(), false, StyleImpact.Paint,
		DecorationChain.interpolate);
	public static final Opacity:StyleProperty<Float> = new StyleProperty(
		"opacity", 1.0, false, StyleImpact.Composite, floatInterpolate);
	/** Ordered post-layout filters applied to this node and its descendants. */
	public static final Effects:StyleProperty<EffectChain> = new StyleProperty(
		"effects", EffectChain.empty(), false, StyleImpact.Composite,
		EffectChain.interpolate);
	/** Ordered filters applied to the already-rendered backdrop behind this node. */
	public static final BackdropEffects:StyleProperty<EffectChain> = new StyleProperty(
		"backdropEffects", EffectChain.empty(), false, StyleImpact.Composite,
		EffectChain.interpolate);
	/** Source-alpha mask applied during isolated-layer composition. */
	public static final Mask:StyleProperty<Mask> = new StyleProperty<Mask>(
		"mask", null, false, StyleImpact.Composite);
	/** Paint inputs used by the retained custom progress renderer. */
	public static final ProgressTrackColor:StyleColorProperty = new StyleColorProperty(
		"progressTrackColor", Color.rgba(0.19, 0.21, 0.25, 1.0), false,
		StyleImpact.Paint, colorInterpolate);
	public static final ProgressFillColor:StyleColorProperty = new StyleColorProperty(
		"progressFillColor", Color.rgba(0.22, 0.52, 0.84, 1.0), false,
		StyleImpact.Paint, colorInterpolate);
	/** Paint inputs used by the retained custom slider renderer. */
	public static final SliderTrackColor:StyleColorProperty = new StyleColorProperty(
		"sliderTrackColor", Color.rgba(0.16, 0.18, 0.22, 1.0), false,
		StyleImpact.Paint, colorInterpolate);
	public static final SliderFillColor:StyleColorProperty = new StyleColorProperty(
		"sliderFillColor", Color.rgba(0.22, 0.48, 0.86, 1.0), false,
		StyleImpact.Paint, colorInterpolate);
	public static final SliderThumbColor:StyleColorProperty = new StyleColorProperty(
		"sliderThumbColor", Color.rgba(0.96, 0.97, 0.99, 1.0), false,
		StyleImpact.Paint, colorInterpolate);

	/** Inherited typography/paint inputs are computed here and applied by text widgets. */
	public static final TextColor:StyleColorProperty = new StyleColorProperty(
		"textColor", Color.rgba(1.0, 1.0, 1.0, 1.0), true, StyleImpact.Paint);
	public static final FontSize:StyleProperty<Float> = new StyleProperty(
		"fontSize", 16.0, true, StyleImpact.Layout | StyleImpact.TextLayout | StyleImpact.Paint);
	public static final LetterSpacing:StyleProperty<Float> = new StyleProperty(
		"letterSpacing", 0.0, true, StyleImpact.TextLayout | StyleImpact.Paint);

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
				baseProperty(OutlineColor), baseProperty(OutlineWidth), baseProperty(ShadowColor),
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

/** A color property retains its typed comparison and interpolation callbacks. */
class StyleColorProperty extends StylePropertyBase {
	public final defaultValue:Color;
	final colorEqual:Null<Color->Color->Bool>;
	final colorInterpolate:Null<Color->Color->Float->Color>;
	public function new(name:String, defaultValue:Color, inherited:Bool, impact:StyleImpact,
			?interpolate:Color->Color->Float->Color, ?equalValue:Color->Color->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact, interpolate != null);
		this.defaultValue = defaultValue;
		colorEqual = equalValue;
		colorInterpolate = interpolate;
	}
	public function sameColor(left:Color, right:Color):Bool
		return colorEqual == null ? haxeon.Equality.equals(left, right) : colorEqual(left, right);
	public function interpolateColor(left:Color, right:Color, amount:Float):Color {
		if (colorInterpolate == null) throw "Style property does not support interpolation";
		return colorInterpolate(left, right, amount);
	}
}

/** Typed value properties avoid erasing struct comparisons to Dynamic. */
class StyleInsetsProperty extends StylePropertyBase {
	public final defaultValue:Insets;
	final insetsEqual:Null<Insets->Insets->Bool>;
	public function new(name:String, defaultValue:Insets, inherited:Bool, impact:StyleImpact,
			?equalValue:Insets->Insets->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact, false);
		this.defaultValue = defaultValue;
		insetsEqual = equalValue;
	}
	public function sameInsets(left:Insets, right:Insets):Bool
		return insetsEqual == null ? haxeon.Equality.equals(left, right) : insetsEqual(left, right);
}

class StyleAxisProperty extends StylePropertyBase {
	public final defaultValue:LayoutAxis;
	final axisEqual:Null<LayoutAxis->LayoutAxis->Bool>;
	public function new(name:String, defaultValue:LayoutAxis, inherited:Bool, impact:StyleImpact,
			?equalValue:LayoutAxis->LayoutAxis->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact, false);
		this.defaultValue = defaultValue;
		axisEqual = equalValue;
	}
	public function sameAxis(left:LayoutAxis, right:LayoutAxis):Bool
		return axisEqual == null ? haxeon.Equality.equals(left, right) : axisEqual(left, right);
}

class StyleTransformProperty extends StylePropertyBase {
	public final defaultValue:Transform2D;
	final transformEqual:Null<Transform2D->Transform2D->Bool>;
	public function new(name:String, defaultValue:Transform2D, inherited:Bool, impact:StyleImpact,
			?equalValue:Transform2D->Transform2D->Bool) {
		super(name, StyleProperty.allocateSlot(name), inherited, impact, false);
		this.defaultValue = defaultValue;
		transformEqual = equalValue;
	}
	public function sameTransform(left:Transform2D, right:Transform2D):Bool
		return transformEqual == null ? haxeon.Equality.equals(left, right) : transformEqual(left, right);
}
