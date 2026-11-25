package haxeon.ui.core;

import haxeon.ui.Canvas;
import haxeon.ui.GraphicsSurface;
import haxeon.ui.Rect;

/** Adapts a retained NativeKit GPU image/surface to a viewport content plane. */
class GraphicsSurfaceViewportContent implements ViewportContent {
	/** The GPU surface shown. */
	public final surface:GraphicsSurface;

	/** The content width, in logical pixels. */
	public final contentWidth:Float;

	/** The content height, in logical pixels. */
	public final contentHeight:Float;

	/** Counts the changes `invalidate` reports. */
	public var contentRevision(default, null):Int;

	/** Viewport content showing `surface` at `width` by `height` logical pixels. */
	public function new(surface:GraphicsSurface, width:Float, height:Float) {
		if (surface == null || surface.isDisposed() || width <= 0.0 || height <= 0.0 || !finite(width)
			|| !finite(height))
			throw "Graphics viewport content requires a live surface and positive dimensions";
		this.surface = surface;
		contentWidth = width;
		contentHeight = height;
		contentRevision = 1;
	}

	/** The content width, in logical pixels. */
	public function width():Float
		return contentWidth;

	/** The content height, in logical pixels. */
	public function height():Float
		return contentHeight;

	/** Changes whenever the surface's pixels do. */
	public function revision():Int
		return contentRevision;

	/** Marks the surface pixels as changed without replacing the GPU resource. */
	public function invalidate():Void
		contentRevision++;

	/** Draws the surface scaled into `destination`. */
	public function paint(canvas:Canvas, destination:Rect):Void {
		if (canvas == null || destination == null)
			throw "Graphics viewport painting requires a canvas and destination";
		canvas.drawSurface(surface, destination);
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
