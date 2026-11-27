package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Canvas;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Paint;
import haxeon.ui.Path;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;

/**
 * A reusable path-backed custom view. Hit testing intentionally uses the
 * resolved layout bounds; path-accurate hit testing can be added separately.
 */
class Shape implements View {
	/** Identifies the shape among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The outline drawn. */
	public final path:Path;

	/** The color or gradient it is drawn with. */
	public final paint:Paint;

	/** The shape's box. */
	public final style:LayoutStyle;

	/** Its accessible name; without one, assistive technology skips it. */
	public final label:Null<String>;

	/** Whether it takes pointer events itself, over its own box. */
	public final hitTestSelf:Bool;

	/** Whether the path is filled; otherwise it is stroked. */
	public final filled:Bool;

	/** The stroke's width, when stroked. */
	public final strokeWidth:Float;

	/** How open stroke ends are drawn. */
	public final strokeCap:LineCap;

	/** How stroke corners are drawn. */
	public final strokeJoin:LineJoin;

	/** How far a mitered corner may reach before it is beveled, as a multiple of the stroke width. */
	public final miterLimit:Float;

	/** Whether its drawing is kept as a raster between frames. */
	public final cachePolicy:CachePolicy;

	/** Identifies the drawing, so it is reused across builds while the key is the same. */
	public final cacheKey:Null<String>;

	/** A shape drawing `path` with `paint`; prefer `fill` and `stroke`. */
	public function new(key:String,
			path:Path,
			paint:Paint,
			?style:LayoutStyle,
			?label:String,
			hitTestSelf:Bool = true,
			filled:Bool = true,
			strokeWidth:Float = 1.0,
			strokeCap:LineCap = LineCap.Butt,
			strokeJoin:LineJoin = LineJoin.Miter,
			miterLimit:Float = 4.0,
			cachePolicy:CachePolicy = CachePolicy.None,
			?cacheKey:String) {
		if (key == null || key.length == 0 || path == null || paint == null
			|| path.isDisposed()
			|| paint.isDisposed()) throw "Shapes require a stable key and live path and paint resources";
		if (!filled
			&& (!Math.isFinite(strokeWidth) || strokeWidth <= 0.0))
			throw "Shape stroke width must be positive and finite";
		if (!Math.isFinite(miterLimit) || miterLimit <= 0.0) throw "Shape miter limit must be positive and finite";
		if (cacheKey != null && cacheKey.length == 0) throw "Shape cache keys cannot be empty";
		this.key = key;
		this.path = path;
		this.paint = paint;
		this.style = style == null ? defaultStyle() : style.copy();
		this.label = label;
		this.hitTestSelf = hitTestSelf;
		this.filled = filled;
		this.strokeWidth = strokeWidth;
		this.strokeCap = strokeCap;
		this.strokeJoin = strokeJoin;
		this.miterLimit = miterLimit;
		this.cachePolicy = cachePolicy;
		this.cacheKey = cacheKey;
	}

	/** Creates a filled path shape. */
	public static function fill(key:String,
			path:Path,
			paint:Paint,
			?style:LayoutStyle,
			?label:String,
			hitTestSelf:Bool = true,
			cachePolicy:CachePolicy = CachePolicy.None,
			?cacheKey:String):Shape {
		return new Shape(key,
			path,
			paint,
			style,
			label,
			hitTestSelf,
			true,
			1.0,
			LineCap.Butt,
			LineJoin.Miter,
			4.0,
			cachePolicy,
			cacheKey);
	}

	/** Creates a stroked path shape. */
	public static function stroke(key:String,
			path:Path,
			paint:Paint,
			width:Float,
			?style:LayoutStyle,
			?label:String,
			hitTestSelf:Bool = true,
			cap:LineCap = LineCap.Butt,
			join:LineJoin = LineJoin.Miter,
			miterLimit:Float = 4.0,
			cachePolicy:CachePolicy = CachePolicy.None,
			?cacheKey:String):Shape {
		return new Shape(key,
			path,
			paint,
			style,
			label,
			hitTestSelf,
			false,
			width,
			cap,
			join,
			miterLimit,
			cachePolicy,
			cacheKey);
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), function() {
			var nodeId = context.rootId("shape");
			var node = context.styled(nodeId, LayoutVisualKind.Custom,
				new StyleIdentity("shape", key, key, null, ["shape"]), style);
			node.hitTestSelf = hitTestSelf;
			node.cachePolicy = cachePolicy;
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Group, label);
			node.onPaint(function(canvas, _) {
				if (path.isDisposed() || paint.isDisposed()) return;
				if (filled) canvas.fill(path, paint);
				else canvas.stroke(path, paint, strokeWidth, strokeCap, strokeJoin, miterLimit);
			}, cacheKey);
			return node;
		});
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(160.0);
		result.height = LayoutAxis.fixed(100.0);
		return result;
	}
}
