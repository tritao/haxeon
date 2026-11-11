package haxeon.ui;

/**
 * Haxe-owned mutable layout, paint, visibility, and transform inputs. Field masks are generated from the
 * declaration; the scalar cache fingerprint is explicit and is not a map-key hash.
 */
class LayoutStyle implements Diffable {
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
	@:isVar public var background(get, set):Color;
	@:isVar public var radiusTopLeft(get, set):Float;
	@:isVar public var radiusTopRight(get, set):Float;
	@:isVar public var radiusBottomLeft(get, set):Float;
	@:isVar public var radiusBottomRight(get, set):Float;
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

	function get_background():Color {
		var binding = PaintBindings.style(this);
		if (binding == null) return background;
		var slot = binding.store.at(binding.index, binding.generation);
		return new Color(slot.ref.backgroundRed, slot.ref.backgroundGreen, slot.ref.backgroundBlue, slot.ref.backgroundAlpha);
	}

	function set_background(value:Color):Color {
		var binding = PaintBindings.style(this);
		if (binding == null) return background = value;
		while (binding != null) {
			binding.store.setBackground(binding.index, binding.generation, value.red, value.green, value.blue, value.alpha);
			binding = binding.nextStyle;
		}
		return value;
	}

	function get_radiusTopLeft():Float {
		var binding = PaintBindings.style(this);
		return binding == null ? radiusTopLeft : binding.store.at(binding.index, binding.generation).ref.radiusTopLeft;
	}
	function get_radiusTopRight():Float {
		var binding = PaintBindings.style(this);
		return binding == null ? radiusTopRight : binding.store.at(binding.index, binding.generation).ref.radiusTopRight;
	}
	function get_radiusBottomLeft():Float {
		var binding = PaintBindings.style(this);
		return binding == null ? radiusBottomLeft : binding.store.at(binding.index, binding.generation).ref.radiusBottomLeft;
	}
	function get_radiusBottomRight():Float {
		var binding = PaintBindings.style(this);
		return binding == null ? radiusBottomRight : binding.store.at(binding.index, binding.generation).ref.radiusBottomRight;
	}
	function set_radiusTopLeft(value:Float):Float {
		if (PaintBindings.style(this) == null) return radiusTopLeft = value;
		setRadius(0, value); return value;
	}
	function set_radiusTopRight(value:Float):Float {
		if (PaintBindings.style(this) == null) return radiusTopRight = value;
		setRadius(1, value); return value;
	}
	function set_radiusBottomLeft(value:Float):Float {
		if (PaintBindings.style(this) == null) return radiusBottomLeft = value;
		setRadius(2, value); return value;
	}
	function set_radiusBottomRight(value:Float):Float {
		if (PaintBindings.style(this) == null) return radiusBottomRight = value;
		setRadius(3, value); return value;
	}
	function setRadius(corner:Int, value:Float):Void {
		var binding = PaintBindings.style(this);
		while (binding != null) {
			var slot = binding.store.at(binding.index, binding.generation);
			switch corner {
				case 0: if (!PaintStore.sameFloat(slot.ref.radiusTopLeft, value)) { slot.ref.radiusTopLeft = value; slot.ref.flags |= 2; }
				case 1: if (!PaintStore.sameFloat(slot.ref.radiusTopRight, value)) { slot.ref.radiusTopRight = value; slot.ref.flags |= 2; }
				case 2: if (!PaintStore.sameFloat(slot.ref.radiusBottomLeft, value)) { slot.ref.radiusBottomLeft = value; slot.ref.flags |= 2; }
				case 3: if (!PaintStore.sameFloat(slot.ref.radiusBottomRight, value)) { slot.ref.radiusBottomRight = value; slot.ref.flags |= 2; }
				default: throw "Invalid paint corner";
			}
			binding = binding.nextStyle;
		}
	}

	/** Returns an independent style value for compositional widget builders: every field, generated from the declaration. */
	public function copy():LayoutStyle
		return haxeon.Diff.copy(this);

}
