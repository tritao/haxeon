package haxeon.ui;


/**
 * Haxe-owned mutable layout, paint, visibility, and transform inputs. Field masks are generated from the
 * declaration; the scalar cache fingerprint is explicit and is not a map-key hash.
 */
class LayoutStyle implements Diffable {
	/** The box's width. */
	public var width:LayoutAxis;

	/** The box's height. */
	public var height:LayoutAxis;
	/** Width divided by height; zero disables aspect-ratio sizing. */
	public var aspectRatio:Float;

	/** Whether children are laid out top to bottom or left to right. */
	public var direction:LayoutDirection;

	/** Where children sit horizontally. */
	public var childAlignX:LayoutAlignmentX;

	/** Where children sit vertically. */
	public var childAlignY:LayoutAlignmentY;
	/** Main-axis free-space distribution policy. */
	public var childDistribution:LayoutDistribution;

	/** Whether the box flows with its siblings or is placed at its position. */
	public var positioning:LayoutPositioning;
	/** Controls whether children flow onto additional rows or columns. */
	public var wrapMode:LayoutWrapMode;
	/** Vertical gap between wrapped rows. */
	public var rowGap:Float;
	/** Horizontal gap between wrapped columns. */
	public var columnGap:Float;
	/** Cross-axis alignment override when this node is a child. */
	public var alignSelf:LayoutSelfAlignment;

	/** Its left edge within its parent, when placed. */
	public var positionX:Float;

	/** Its top edge within its parent, when placed. */
	public var positionY:Float;

	/** Its stacking order among siblings. */
	public var zIndex:Int;

	/** Whether its parent's clip applies to it. */
	public var clipToParent:Bool;
	/** Paint above ordinary content, scoped to the nearest enclosing overlay. Requires Absolute positioning. */
	public var overlay:Bool;

	/** Space between its edges and its children. */
	public var padding:Insets;

	/** Space between consecutive children. */
	public var childGap:Float;

	/** Its fill. */
	public var background:Color;

	/** Its top-left corner radius. */
	public var radiusTopLeft:Float;

	/** Its top-right corner radius. */
	public var radiusTopRight:Float;

	/** Its bottom-left corner radius. */
	public var radiusBottomLeft:Float;

	/** Its bottom-right corner radius. */
	public var radiusBottomRight:Float;

	/** Whether children are clipped at its left and right edges. */
	public var clipHorizontal:Bool;

	/** Whether children are clipped at its top and bottom edges. */
	public var clipVertical:Bool;

	/** Whether it is drawn and hit tested; hidden, it keeps its place in layout. */
	public var visible:Bool;

	/** A transform applied when compositing; layout is unaffected. */
	public var transform:Transform2D;
	/** Normalized horizontal pivot used after layout resolves the node width. */
	public var transformOriginX:Float;
	/** Normalized vertical pivot used after layout resolves the node height. */
	public var transformOriginY:Float;

	/** Insets, Color and Transform2D are immutable, so every style can start from the same default values. */
	static final DefaultPadding:Insets = new Insets(0.0, 0.0, 0.0, 0.0);

	static final DefaultBackground:Color = Color.rgba(0.0, 0.0, 0.0, 0.0);

	static final DefaultTransform:Transform2D = Transform2D.identity();

	/** The default style: fit to content, top to bottom, transparent. */
	public function new() {
		width = LayoutAxis.fit();
		height = LayoutAxis.fit();
		aspectRatio = 0.0;
		direction = LayoutDirection.TopToBottom;
		childAlignX = LayoutAlignmentX.Start;
		childAlignY = LayoutAlignmentY.Start;
		childDistribution = LayoutDistribution.Start;
		positioning = LayoutPositioning.Flow;
		wrapMode = LayoutWrapMode.NoWrap;
		rowGap = 0.0;
		columnGap = 0.0;
		alignSelf = LayoutSelfAlignment.Inherit;
		positionX = 0.0;
		positionY = 0.0;
		zIndex = 0;
		clipToParent = true;
		overlay = false;
		padding = DefaultPadding;
		childGap = 0.0;
		background = DefaultBackground;
		radiusTopLeft = 0.0;
		radiusTopRight = 0.0;
		radiusBottomLeft = 0.0;
		radiusBottomRight = 0.0;
		clipHorizontal = false;
		clipVertical = false;
		visible = true;
		transform = DefaultTransform;
		transformOriginX = 0.5;
		transformOriginY = 0.5;
	}

	/** Returns an independent style value for compositional widget builders: every field, generated from the declaration. */
	public function copy():LayoutStyle
		return haxeon.Diff.copy(this);

}

/** Child flow direction used by the native layout engine. */
typedef LayoutDirection = NativeKitUI.UiLayoutDirection;

/** Cross-axis alignment for children in a top-to-bottom layout. */
typedef LayoutAlignmentX = NativeKitUI.UiLayoutAlignmentX;

/** Cross-axis alignment for children in a left-to-right layout. */
typedef LayoutAlignmentY = NativeKitUI.UiLayoutAlignmentY;

/** Main-axis free-space distribution policy. */
typedef LayoutDistribution = NativeKitUI.UiLayoutDistribution;

/** Optional per-child cross-axis alignment override. */
typedef LayoutSelfAlignment = NativeKitUI.UiLayoutSelfAlignment;

/** Child flow policy for layout containers. */
typedef LayoutWrapMode = NativeKitUI.UiLayoutWrapMode;

/** Whether a node participates in parent flow or floats over sibling layout. */
enum LayoutPositioning implements Hashable {
	/** Laid out with its siblings. */
	Flow;
	/** Placed at its position within its parent, outside the siblings' flow. */
	Absolute;
}
