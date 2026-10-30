package haxeon.ui;

/**
 * Haxe-owned layout, paint, visibility, and transform data. Structural: copying, comparing, hashing and diffing go through
 * haxeon.Structural, generated from the fields below, so a field added here is covered by all of them.
 */
@:structural
class LayoutStyle {
	public var width:LayoutAxis;
	public var height:LayoutAxis;
	/** Width divided by height; zero disables aspect-ratio sizing. */
	public var aspectRatio:Float;
	public var direction:LayoutDirection;
	public var childAlignX:LayoutAlignmentX;
	public var childAlignY:LayoutAlignmentY;
	/** Main-axis free-space distribution policy. */
	public var childDistribution:LayoutDistribution;
	public var positioning:LayoutPositioning;
	/** Controls whether children flow onto additional rows or columns. */
	public var wrapMode:LayoutWrapMode;
	/** Vertical gap between wrapped rows. */
	public var rowGap:Float;
	/** Horizontal gap between wrapped columns. */
	public var columnGap:Float;
	/** Cross-axis alignment override when this node is a child. */
	public var alignSelf:LayoutSelfAlignment;
	public var positionX:Float;
	public var positionY:Float;
	public var zIndex:Int;
	public var clipToParent:Bool;
	/** Paint above ordinary content, scoped to the nearest enclosing overlay. Requires Absolute positioning. */
	public var overlay:Bool;
	public var padding:Insets;
	public var childGap:Float;
	public var background:Color;
	public var radiusTopLeft:Float;
	public var radiusTopRight:Float;
	public var radiusBottomLeft:Float;
	public var radiusBottomRight:Float;
	public var clipHorizontal:Bool;
	public var clipVertical:Bool;
	public var visible:Bool;
	public var transform:Transform2D;
	/** Normalized horizontal pivot used after layout resolves the node width. */
	public var transformOriginX:Float;
	/** Normalized vertical pivot used after layout resolves the node height. */
	public var transformOriginY:Float;

	/** Insets, Color and Transform2D are immutable, so every style can start from the same default values. */
	static final DefaultPadding:Insets = new Insets(0.0, 0.0, 0.0, 0.0);

	static final DefaultBackground:Color = Color.rgba(0.0, 0.0, 0.0, 0.0);

	static final DefaultTransform:Transform2D = Transform2D.identity();

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
		return haxeon.Structural.copy(this);

}
