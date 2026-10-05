package haxeon.ui;

import haxeon.ui.Canvas;
import haxeon.ui.DisplayList;
import haxeon.ui.Rect;

/** Paint callback for a retained custom layout content provider. */
typedef LayoutContentPaint = (canvas:Canvas, geometry:ResolvedLayoutItem) -> Void;

/**
 * Pairs intrinsic measurement with a retained Canvas display list.
 *
 * The painter draws in the custom node's local layout space. LayoutSession
 * applies the resolved position, transform, and ancestor clipping when the
 * list is embedded, matching the framework RenderNode paint contract. The
 * display list is regenerated when the provider version or resolved paint
 * geometry changes. Painters can use visibleLocalBounds() to cull their work.
 */
class LayoutRenderableContent implements LayoutContent {
	final measurement:LayoutContent;
	final painter:LayoutContentPaint;
	final canvas:Canvas;
	final list:DisplayList;
	var paintedVersion:Int;
	var paintedGeometry:Null<ResolvedLayoutItem>;

	public function new(measurement:LayoutContent, painter:LayoutContentPaint,
			canvasCapacity:Int = 4096) {
		if (measurement == null || painter == null)
			throw "Renderable content requires measurement and paint callbacks";
		this.measurement = measurement;
		this.painter = painter;
		canvas = new Canvas(canvasCapacity);
		list = DisplayList.create();
		paintedVersion = -1;
		paintedGeometry = null;
	}

	public function getVersion():Int
		return measurement.getVersion();

	public function measure(constraints:LayoutMeasureConstraints):LayoutMeasureResult
		return measurement.measure(constraints);

	public function asRenderable():Null<LayoutRenderableContent>
		return this;

	/** Rebuilds and returns the retained display list when its cache key changed. */
	public function paint(geometry:ResolvedLayoutItem):DisplayList {
		if (geometry == null)
			throw "Renderable content requires resolved geometry";
		var version = getVersion();
		if (paintedGeometry != null && paintedVersion == version &&
			geometryEqual(paintedGeometry, geometry))
			return list;

		canvas.reset();
		canvas.withState(function(target) {
			target.resetTransform();
			target.clip(geometry.visibleLocalBounds());
			painter(target, geometry);
		});
		list.update(canvas);
		paintedVersion = version;
		paintedGeometry = geometry;
		return list;
	}

	/** Invalidates drawing while preserving intrinsic measurement and shaped resources. */
	public function invalidatePaint():Void {
		paintedVersion = -1;
		paintedGeometry = null;
	}

	/** Clears the retained command stream; the next layout render repaints it. */
	public function clear():Void {
		canvas.reset();
		list.clear();
		paintedVersion = -1;
		paintedGeometry = null;
	}

	/** Releases the retained display list and its referenced graphics resources. */
	public function dispose():Void {
		canvas.reset();
		list.dispose();
		paintedGeometry = null;
	}

	static function geometryEqual(a:ResolvedLayoutItem, b:ResolvedLayoutItem):Bool {
		return a.flags == b.flags && a.x == b.x && a.y == b.y &&
			a.width == b.width && a.height == b.height && a.baseline == b.baseline &&
			sameRect(a.clipBounds, b.clipBounds) &&
			sameRect(a.contentBounds, b.contentBounds) &&
			a.transform.a == b.transform.a && a.transform.b == b.transform.b &&
			a.transform.c == b.transform.c && a.transform.d == b.transform.d &&
			a.transform.tx == b.transform.tx && a.transform.ty == b.transform.ty;
	}

	static function sameRect(a:Rect, b:Rect):Bool
		return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}
