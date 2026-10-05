package haxeon.ui;

import haxe.io.Bytes;

/** Frame-scoped layout, clipping, content, visibility, and transform geometry. */
class ResolvedLayoutItem {
	public final id:Int;
	public final flags:Int;
	public final x:Float;
	public final y:Float;
	public final width:Float;
	public final height:Float;
	public final clipBounds:Rect;
	public final contentBounds:Rect;
	public final transform:Transform2D;
	public final baseline:Float;

	public function new(id:Int, flags:Int, x:Float, y:Float, width:Float, height:Float,
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

	public var visible(get, never):Bool;
	inline function get_visible():Bool
		return (flags & 1) != 0;

	public var hasBaseline(get, never):Bool;
	inline function get_hasBaseline():Bool
		return (flags & 2) != 0;

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

	public inline function viewportToLocalY(viewportX:Float, viewportY:Float):Float
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

	public static function decode(bytes:Bytes, offset:Int):ResolvedLayoutItem {
		var recordBytes = NativeKitUIConstants.NKUI_LAYOUT_RESOLVED_ITEM_BYTES;
		if (offset < 0 || offset > bytes.length || recordBytes > bytes.length - offset)
			throw "Resolved layout item is outside the geometry snapshot";
		if (bytes.getInt32(offset) != recordBytes)
			throw "Resolved layout item has an unsupported record size";
		var flags = bytes.getInt32(offset + 8);
		if ((flags & ~3) != 0)
			throw "Native layout returned unsupported resolved flags";
		return new ResolvedLayoutItem(bytes.getInt32(offset + 4), flags,
			readFloat(bytes, offset + 12), readFloat(bytes, offset + 16),
			readFloat(bytes, offset + 20), readFloat(bytes, offset + 24),
			new Rect(readFloat(bytes, offset + 28), readFloat(bytes, offset + 32),
				readFloat(bytes, offset + 36), readFloat(bytes, offset + 40)),
			new Rect(readFloat(bytes, offset + 44), readFloat(bytes, offset + 48),
				readFloat(bytes, offset + 52), readFloat(bytes, offset + 56)),
			new Transform2D(readFloat(bytes, offset + 60), readFloat(bytes, offset + 64),
				readFloat(bytes, offset + 68), readFloat(bytes, offset + 72),
				readFloat(bytes, offset + 76), readFloat(bytes, offset + 80)),
			readFloat(bytes, offset + 84));
	}

	static inline function contains(rect:Rect, x:Float, y:Float):Bool
		return x >= rect.x && y >= rect.y && x <= rect.x + rect.width && y <= rect.y + rect.height;

	static inline function readFloat(bytes:Bytes, offset:Int):Float
		return floatFromBits(bytes.getInt32(offset));

	static function floatFromBits(bits:Int):Float {
		var sign = (bits >>> 31) == 0 ? 1.0 : -1.0;
		var exponent = (bits >>> 23) & 0xff;
		var fraction = bits & 0x7fffff;
		if (exponent == 255)
			throw "Native layout returned a non-finite geometry value";
		if (exponent == 0)
			return sign * fraction * Math.pow(2.0, -149.0);
		return sign * (0x800000 | fraction) * Math.pow(2.0, exponent - 150.0);
	}
}
