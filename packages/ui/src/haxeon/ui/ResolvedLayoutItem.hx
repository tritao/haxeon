package haxeon.ui;

/** Frame-scoped layout, clipping, content, visibility, and transform geometry. */
class ResolvedLayoutItem {
	/** The node it is the layout of. */
	public final id:Int;
	internal final flags:Int;

	/** Its left edge, in layout coordinates: before `transform` maps it to the viewport. */
	public final x:Float;

	/** Its top edge, in layout coordinates. */
	public final y:Float;

	/** Its width. */
	public final width:Float;

	/** Its height. */
	public final height:Float;

	/** The area its drawing is clipped to, in viewport coordinates. */
	public final clipBounds:Rect;

	/** The area its children cover. */
	public final contentBounds:Rect;

	/** Its transform to viewport coordinates. */
	public final transform:Transform2D;

	/** Its first text baseline, from its top, when `hasBaseline`. */
	public final baseline:Float;

	internal function new(id:Int, flags:Int, x:Float, y:Float, width:Float, height:Float,
			clipBounds:Rect, contentBounds:Rect, transform:Transform2D, baseline:Float) {
		this.id = id;
		this.flags = flags;
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		this.clipBounds = clipBounds;
		this.contentBounds = contentBounds;
		this.transform = transform;
		this.baseline = baseline;
	}

	/** Whether it is drawn. */
	public var visible(get, never):Bool;
	inline function get_visible():Bool
		return (flags & 1) != 0;

	/** Whether it has a baseline to align by. */
	public var hasBaseline(get, never):Bool;
	inline function get_hasBaseline():Bool
		return (flags & 2) != 0;

	/** Its box, in layout coordinates. */
	public inline function bounds():Rect
		return new Rect(x, y, width, height);

	/** The node's local space always starts at its own top-left corner. */
	public inline function localBounds():Rect
		return new Rect(0.0, 0.0, width, height);

	/** Converts a point from this node's local space into viewport space. */
	public function localToViewport(point:Point):Point {
		if (point == null)
			throw "Local points cannot be null";
		var absoluteX = x + point.x, absoluteY = y + point.y;
		return new Point(transform.transformedX(absoluteX, absoluteY), transform.transformedY(absoluteX, absoluteY));
	}

	/** Whether viewport points can be mapped into this node's space (its transform is invertible). */
	public inline function canMapViewport():Bool
		return transform.isInvertible();

	/** Allocation-free viewportToLocal for callers that checked canMapViewport(). */
	public inline function viewportToLocalX(viewportX:Float, viewportY:Float):Float
		return transform.inverseTransformedX(viewportX, viewportY) - x;

	internal inline function viewportToLocalY(viewportX:Float, viewportY:Float):Float
		return transform.inverseTransformedY(viewportX, viewportY) - y;

	/** Attempts to convert a viewport point into this node's local space. */
	public function tryViewportToLocal(point:Point):Null<Point> {
		if (point == null)
			throw "Viewport points cannot be null";
		if (!canMapViewport())
			return null;
		return new Point(viewportToLocalX(point.x, point.y), viewportToLocalY(point.x, point.y));
	}

	/** Converts a viewport point into this node's local space. */
	public function viewportToLocal(point:Point):Point {
		var result = tryViewportToLocal(point);
		if (result == null)
			throw "Resolved layout transform is not invertible";
		return result;
	}

	/** Returns the axis-aligned viewport bounds of this transformed node. */
	public function viewportBounds():Rect {
		var farX = x + width, farY = y + height;
		var topLeftX = transform.transformedX(x, y), topLeftY = transform.transformedY(x, y);
		var topRightX = transform.transformedX(farX, y), topRightY = transform.transformedY(farX, y);
		var bottomLeftX = transform.transformedX(x, farY), bottomLeftY = transform.transformedY(x, farY);
		var bottomRightX = transform.transformedX(farX, farY), bottomRightY = transform.transformedY(farX, farY);
		var left = Math.min(Math.min(topLeftX, topRightX), Math.min(bottomLeftX, bottomRightX));
		var top = Math.min(Math.min(topLeftY, topRightY), Math.min(bottomLeftY, bottomRightY));
		var right = Math.max(Math.max(topLeftX, topRightX), Math.max(bottomLeftX, bottomRightX));
		var bottom = Math.max(Math.max(topLeftY, topRightY), Math.max(bottomLeftY, bottomRightY));
		return new Rect(left, top, right - left, bottom - top);
	}

	/** Returns the transformed bounds intersected with the resolved clip. */
	public function clippedViewportBounds():Rect {
		var bounds = viewportBounds();
		var left = Math.max(bounds.x, clipBounds.x);
		var top = Math.max(bounds.y, clipBounds.y);
		var right = Math.min(bounds.x + bounds.width, clipBounds.x + clipBounds.width);
		var bottom = Math.min(bounds.y + bounds.height, clipBounds.y + clipBounds.height);
		return new Rect(left, top, Math.max(0.0, right - left),
			Math.max(0.0, bottom - top));
	}

	/** Conservative visible rectangle in node-local coordinates for custom painters. */
	public function visibleLocalBounds():Rect {
		var visible = clippedViewportBounds();
		if (visible.width <= 0.0 || visible.height <= 0.0)
			return new Rect(0.0, 0.0, 0.0, 0.0);
		if (!canMapViewport())
			return localBounds();
		var farX = visible.x + visible.width, farY = visible.y + visible.height;
		var left = width;
		var top = height;
		var right = 0.0;
		var bottom = 0.0;
		for (corner in 0...4) {
			var viewportX = (corner & 1) == 0 ? visible.x : farX;
			var viewportY = (corner & 2) == 0 ? visible.y : farY;
			var localX = viewportToLocalX(viewportX, viewportY);
			var localY = viewportToLocalY(viewportX, viewportY);
			left = Math.min(left, localX);
			top = Math.min(top, localY);
			right = Math.max(right, localX);
			bottom = Math.max(bottom, localY);
		}
		left = Math.max(0.0, left);
		top = Math.max(0.0, top);
		right = Math.min(width, right);
		bottom = Math.min(height, bottom);
		return new Rect(left, top, Math.max(0.0, right - left),
			Math.max(0.0, bottom - top));
	}

	/** Converts a viewport point back to this node's pre-transform layout space. */
	public function viewportToLayout(x:Float, y:Float):Point {
		if (!transform.isInvertible())
			throw "Resolved layout transform is not invertible";
		return new Point(transform.inverseTransformedX(x, y), transform.inverseTransformedY(x, y));
	}

	/** Checks visibility, inherited clipping, and the transformed node bounds. */
	public function hitTest(x:Float, y:Float):Bool {
		if (!visible || !contains(clipBounds, x, y))
			return false;
		if (!canMapViewport())
			return false;
		var localX = viewportToLocalX(x, y), localY = viewportToLocalY(x, y);
		return localX >= 0.0 && localY >= 0.0 && localX <= width && localY <= height;
	}

	static inline function contains(rect:Rect, x:Float, y:Float):Bool
		return x >= rect.x && y >= rect.y && x <= rect.x + rect.width && y <= rect.y + rect.height;
}
