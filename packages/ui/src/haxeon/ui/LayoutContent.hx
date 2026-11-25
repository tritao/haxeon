package haxeon.ui;

import NativeKitUI;
import haxeon.ui.Canvas;
import haxeon.ui.DisplayList;

/** Host-owned intrinsic content that can participate in Custom-node layout. */
interface LayoutContent {
	/** Application-defined cache token; change it whenever intrinsic metrics change. */
	function getVersion():Int;

	/** The content's size within `constraints`. */
	function measure(constraints:LayoutMeasureConstraints):LayoutMeasureResult;

	/** Returns a paint provider when this content owns a retained display list. */
	function asRenderable():Null<LayoutRenderableContent>;
}

/** Immutable intrinsic provider for an uploaded Image resource. */
class LayoutImageContent implements LayoutContent {
	/** The image measured. */
	public final image:Image;

	/** Content measured as `image`'s size. */
	public function new(image:Image) {
		if (image == null || image.isDisposed())
			throw "Image content requires a live image";
		this.image = image;
	}

	public function getVersion():Int
		return 0;

	/** The image's own size, in pixels; `constraints` do not change it. */
	public function measure(constraints:LayoutMeasureConstraints):LayoutMeasureResult
		return new LayoutMeasureResult(image.width, image.height);

	public function asRenderable():Null<LayoutRenderableContent>
		return null;
}

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
class LayoutRenderableContent implements LayoutContent implements Disposable {
	final measurement:LayoutContent;
	final painter:LayoutContentPaint;
	final canvas:Canvas;
	final list:DisplayList;
	var paintedVersion:Int;
	var paintedGeometry:Null<ResolvedLayoutItem>;

	/** Content measured by `measurement` and drawn by `painter`. */
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
		if (paintedGeometry != null && paintedVersion == version && geometryEqual(paintedGeometry, geometry))
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
		// Everything but the id; the rectangles and the transform are compared by their classes' generated equality.
		return a.flags == b.flags && a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
			&& a.baseline == b.baseline && haxeon.Equality.equals(a.clipBounds, b.clipBounds)
			&& haxeon.Equality.equals(a.contentBounds, b.contentBounds)
			&& haxeon.Equality.equals(a.transform, b.transform);
	}
}

/** Adapt a canvas, native view, editor, or other host surface to layout measurement. */
class LayoutMeasuredContent implements LayoutContent {
	final callback:LayoutContentMeasure;
	var versionValue:Int;

	/**
	 * Content measured by `callback`; raise `version` when its size may have changed, so layout measures it again.
	 * Throws without a callback or with a negative version.
	 */
	public function new(callback:LayoutContentMeasure, version:Int = 0) {
		if (callback == null || version < 0)
			throw "Measured content requires a callback and non-negative version";
		this.callback = callback;
		versionValue = version;
	}

	public function getVersion():Int
		return versionValue;

	/** Marks host content as changed without replacing the provider. */
	public function invalidate():Void {
		if (versionValue == 0x7fffffff)
			throw "Measured content version exhausted";
		versionValue++;
	}

	/** Sets an externally managed content version. */
	public function setVersion(version:Int):Void {
		if (version < 0)
			throw "Measured content version must be non-negative";
		versionValue = version;
	}

	/** What `callback` measures within `constraints`. */
	public function measure(constraints:LayoutMeasureConstraints):LayoutMeasureResult
		return callback(constraints);

	public function asRenderable():Null<LayoutRenderableContent>
		return null;
}

/** Measures content within the constraints it is given. */
typedef LayoutContentMeasure = (constraints:LayoutMeasureConstraints) -> LayoutMeasureResult;

/** High-level synchronous intrinsic measurement callback for custom nodes. */
typedef LayoutMeasureCallback = (nodeId:Int, constraints:LayoutMeasureConstraints) -> LayoutMeasureResult;

/** Constraint range supplied while NativeKit measures a custom layout node. */
class LayoutMeasureConstraints {
	/** The narrowest the content may be. */
	public final minWidth:Float;
	/** The widest it may be. */
	public final maxWidth:Float;
	/** The shortest it may be. */
	public final minHeight:Float;
	/** The tallest it may be. */
	public final maxHeight:Float;

	private function new(minWidth:Float, maxWidth:Float, minHeight:Float, maxHeight:Float) {
		this.minWidth = minWidth;
		this.maxWidth = maxWidth;
		this.minHeight = minHeight;
		this.maxHeight = maxHeight;
	}

	@:allow(haxeon.ui.LayoutSession)
	private static function fromNative(value:nkui_layout_measure_constraints):LayoutMeasureConstraints {
		return new LayoutMeasureConstraints(value.get_min_width(), value.get_max_width(),
			value.get_min_height(), value.get_max_height());
	}
}

/** Intrinsic size and optional baseline returned for a custom layout node. */
class LayoutMeasureResult {
	/** The measured width. */
	public final width:Float;
	/** The measured height. */
	public final height:Float;
	/** The first text baseline, from the top, when `hasBaseline`. */
	public final baseline:Float;
	/** Whether the content has a baseline to align by. */
	public final hasBaseline:Bool;

	/** A measured size, with a baseline when `hasBaseline`. */
	public function new(width:Float, height:Float, ?baseline:Float = 0.0,
			hasBaseline:Bool = false) {
		if (width < 0.0 || height < 0.0 || width != width || height != height)
			throw "Measured dimensions must be finite and non-negative";
		if (hasBaseline && (baseline < 0.0 || baseline > height || baseline != baseline))
			throw "Measured baseline must be within the measured height";
		this.width = width;
		this.height = height;
		this.baseline = baseline;
		this.hasBaseline = hasBaseline;
	}

	@:allow(haxeon.ui.LayoutSession)
	private function nativeValue():nkui_layout_measure_result {
		var result = new nkui_layout_measure_result();
		result.set_width(width);
		result.set_height(height);
		result.set_baseline(baseline);
		result.set_flags(NativeKitUI.NkuiLayoutMeasureFlags.fromRaw(hasBaseline ? 1 : 0));
		return result;
	}
}

/** Snapshot of intrinsic measurement and persistent-cache activity. */
class LayoutMeasureStats {
	/** How many measurements layout asked for. */
	public final requests:haxe.Int64;
	/** How many the cache answered. */
	public final cacheHits:haxe.Int64;
	/** How many it did not. */
	public final cacheMisses:haxe.Int64;
	/** How many called a content's measure. */
	public final callbackCalls:haxe.Int64;
	/** How many results the cache holds. */
	public final cacheEntries:haxe.Int64;
	/** How many it can hold. */
	public final cacheCapacity:haxe.Int64;

	/** A snapshot of the counts. */
	public function new(requests:haxe.Int64, cacheHits:haxe.Int64, cacheMisses:haxe.Int64,
			callbackCalls:haxe.Int64, cacheEntries:haxe.Int64, cacheCapacity:haxe.Int64) {
		this.requests = requests;
		this.cacheHits = cacheHits;
		this.cacheMisses = cacheMisses;
		this.callbackCalls = callbackCalls;
		this.cacheEntries = cacheEntries;
		this.cacheCapacity = cacheCapacity;
	}
}
