package haxeon.ui;


/**
 * Haxe-owned mutable layout, paint, visibility, and transform inputs. Field masks are generated from the
 * declaration; the scalar cache fingerprint is explicit and is not a map-key hash.
 *
 * A style records which fields were assigned since it was made (`assigned`), so a widget's style overrides the theme in
 * exactly those fields, a value equal to the default included: a transparent background or zero padding over a theme
 * rule that sets one.
 */
class LayoutStyle implements Diffable {
	/** The box's width. */
	public var width(default, set):LayoutAxis;

	/** The box's height. */
	public var height(default, set):LayoutAxis;
	/** Width divided by height; zero disables aspect-ratio sizing. */
	public var aspectRatio(default, set):Float;

	/** Whether children are laid out top to bottom or left to right. */
	public var direction(default, set):LayoutDirection;

	/** Where children sit horizontally. */
	public var childAlignX(default, set):LayoutAlignmentX;

	/** Where children sit vertically. */
	public var childAlignY(default, set):LayoutAlignmentY;
	/** Main-axis free-space distribution policy. */
	public var childDistribution(default, set):LayoutDistribution;

	/** Whether the box flows with its siblings or is placed at its position. */
	public var positioning(default, set):LayoutPositioning;
	/** Controls whether children flow onto additional rows or columns. */
	public var wrapMode(default, set):LayoutWrapMode;
	/** Vertical gap between wrapped rows. */
	public var rowGap(default, set):Float;
	/** Horizontal gap between wrapped columns. */
	public var columnGap(default, set):Float;
	/** Cross-axis alignment override when this node is a child. */
	public var alignSelf(default, set):LayoutSelfAlignment;

	/** Its left edge within its parent, when placed. */
	public var positionX(default, set):Float;

	/** Its top edge within its parent, when placed. */
	public var positionY(default, set):Float;

	/** Its stacking order among siblings. */
	public var zIndex(default, set):Int;

	/** Whether its parent's clip applies to it. */
	public var clipToParent(default, set):Bool;
	/** Paint above ordinary content, scoped to the nearest enclosing overlay. Requires Absolute positioning. */
	public var overlay(default, set):Bool;

	/** Space between its edges and its children. */
	public var padding(default, set):Insets;

	/** Space between consecutive children. */
	public var childGap(default, set):Float;

	/** Its fill. */
	public var background(default, set):Color;

	/** Its top-left corner radius. */
	public var radiusTopLeft(default, set):Float;

	/** Its top-right corner radius. */
	public var radiusTopRight(default, set):Float;

	/** Its bottom-left corner radius. */
	public var radiusBottomLeft(default, set):Float;

	/** Its bottom-right corner radius. */
	public var radiusBottomRight(default, set):Float;

	/** Whether children are clipped at its left and right edges. */
	public var clipHorizontal(default, set):Bool;

	/** Whether children are clipped at its top and bottom edges. */
	public var clipVertical(default, set):Bool;

	/** Whether it is drawn and hit tested; hidden, it keeps its place in layout. */
	public var visible(default, set):Bool;

	/** A transform applied when compositing; layout is unaffected. */
	public var transform(default, set):Transform2D;
	/** Normalized horizontal pivot used after layout resolves the node width. */
	public var transformOriginX(default, set):Float;
	/** Normalized vertical pivot used after layout resolves the node height. */
	public var transformOriginY(default, set):Float;

	/** The fields assigned since the style was made, as Diff bits; a copy keeps them. */
	public var assigned(default, null):Int;

	/** The Diff bits of the fields that describe the box: every field but `assigned`, which records them. */
	public static final valueFields:Int = haxeon.Diff.all(LayoutStyle) & ~haxeon.Diff.bit(\LayoutStyle.assigned);

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
		// The defaults are not assignments.
		assigned = 0;
	}

	/** Returns an independent style value for compositional widget builders: every field, generated from the declaration. */
	public function copy():LayoutStyle
		return haxeon.Diff.copy(this);

	inline function set_width(value:LayoutAxis):LayoutAxis {
		assigned |= haxeon.Diff.bit(\LayoutStyle.width);
		return width = value;
	}

	inline function set_height(value:LayoutAxis):LayoutAxis {
		assigned |= haxeon.Diff.bit(\LayoutStyle.height);
		return height = value;
	}

	inline function set_aspectRatio(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.aspectRatio);
		return aspectRatio = value;
	}

	inline function set_direction(value:LayoutDirection):LayoutDirection {
		assigned |= haxeon.Diff.bit(\LayoutStyle.direction);
		return direction = value;
	}

	inline function set_childAlignX(value:LayoutAlignmentX):LayoutAlignmentX {
		assigned |= haxeon.Diff.bit(\LayoutStyle.childAlignX);
		return childAlignX = value;
	}

	inline function set_childAlignY(value:LayoutAlignmentY):LayoutAlignmentY {
		assigned |= haxeon.Diff.bit(\LayoutStyle.childAlignY);
		return childAlignY = value;
	}

	inline function set_childDistribution(value:LayoutDistribution):LayoutDistribution {
		assigned |= haxeon.Diff.bit(\LayoutStyle.childDistribution);
		return childDistribution = value;
	}

	inline function set_positioning(value:LayoutPositioning):LayoutPositioning {
		assigned |= haxeon.Diff.bit(\LayoutStyle.positioning);
		return positioning = value;
	}

	inline function set_wrapMode(value:LayoutWrapMode):LayoutWrapMode {
		assigned |= haxeon.Diff.bit(\LayoutStyle.wrapMode);
		return wrapMode = value;
	}

	inline function set_rowGap(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.rowGap);
		return rowGap = value;
	}

	inline function set_columnGap(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.columnGap);
		return columnGap = value;
	}

	inline function set_alignSelf(value:LayoutSelfAlignment):LayoutSelfAlignment {
		assigned |= haxeon.Diff.bit(\LayoutStyle.alignSelf);
		return alignSelf = value;
	}

	inline function set_positionX(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.positionX);
		return positionX = value;
	}

	inline function set_positionY(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.positionY);
		return positionY = value;
	}

	inline function set_zIndex(value:Int):Int {
		assigned |= haxeon.Diff.bit(\LayoutStyle.zIndex);
		return zIndex = value;
	}

	inline function set_clipToParent(value:Bool):Bool {
		assigned |= haxeon.Diff.bit(\LayoutStyle.clipToParent);
		return clipToParent = value;
	}

	inline function set_overlay(value:Bool):Bool {
		assigned |= haxeon.Diff.bit(\LayoutStyle.overlay);
		return overlay = value;
	}

	inline function set_padding(value:Insets):Insets {
		assigned |= haxeon.Diff.bit(\LayoutStyle.padding);
		return padding = value;
	}

	inline function set_childGap(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.childGap);
		return childGap = value;
	}

	inline function set_background(value:Color):Color {
		assigned |= haxeon.Diff.bit(\LayoutStyle.background);
		return background = value;
	}

	inline function set_radiusTopLeft(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.radiusTopLeft);
		return radiusTopLeft = value;
	}

	inline function set_radiusTopRight(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.radiusTopRight);
		return radiusTopRight = value;
	}

	inline function set_radiusBottomLeft(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.radiusBottomLeft);
		return radiusBottomLeft = value;
	}

	inline function set_radiusBottomRight(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.radiusBottomRight);
		return radiusBottomRight = value;
	}

	inline function set_clipHorizontal(value:Bool):Bool {
		assigned |= haxeon.Diff.bit(\LayoutStyle.clipHorizontal);
		return clipHorizontal = value;
	}

	inline function set_clipVertical(value:Bool):Bool {
		assigned |= haxeon.Diff.bit(\LayoutStyle.clipVertical);
		return clipVertical = value;
	}

	inline function set_visible(value:Bool):Bool {
		assigned |= haxeon.Diff.bit(\LayoutStyle.visible);
		return visible = value;
	}

	inline function set_transform(value:Transform2D):Transform2D {
		assigned |= haxeon.Diff.bit(\LayoutStyle.transform);
		return transform = value;
	}

	inline function set_transformOriginX(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.transformOriginX);
		return transformOriginX = value;
	}

	inline function set_transformOriginY(value:Float):Float {
		assigned |= haxeon.Diff.bit(\LayoutStyle.transformOriginY);
		return transformOriginY = value;
	}

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
