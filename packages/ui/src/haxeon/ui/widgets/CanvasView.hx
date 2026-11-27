package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Canvas;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;

/**
 * Custom Haxe-painted region with ordinary Haxe-routed input handlers.
 * Painters draw in local coordinates; native layout places the retained list.
 */
class CanvasView implements View {
	/** Identifies the canvas among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** Its accessible name; without one, assistive technology skips it. */
	public final label:Null<String>;

	/** The canvas's box. */
	public final style:LayoutStyle;

	/** Whether it takes pointer events itself, over its own box. */
	public final hitTestSelf:Bool;
	/** Native raster reuse policy for this retained paint plane. */
	public final cachePolicy:CachePolicy;
	/** Optional fingerprint for retaining the encoded display list across builds. */
	public final cacheKey:Null<String>;
	final painter:Canvas->ResolvedLayoutItem->Void;
	final handlers:Map<String, Array<UiEvent->Void>>;

	/**
	 * A region painted by `painter`, called with a canvas and the region's laid-out box. Throws when `key` is empty or
	 * there is no painter.
	 */
	public function new(key:String,
			painter:Canvas->ResolvedLayoutItem->Void,
			?style:LayoutStyle,
			?label:String,
			hitTestSelf:Bool = true,
			cachePolicy:CachePolicy = CachePolicy.None,
			?cacheKey:String) {
		if (key == null || key.length == 0 || painter == null) throw "Canvas views require a stable key and painter";
		if (cacheKey != null && cacheKey.length == 0) throw "Canvas view cache keys cannot be empty";
		this.key = key;
		this.label = label;
		this.hitTestSelf = hitTestSelf;
		this.cachePolicy = cachePolicy;
		this.cacheKey = cacheKey;
		this.painter = painter;
		this.style = style == null ? defaultStyle() : style.copy();
		handlers = new Map();
	}

	/** Creates a canvas view whose painter does not need resolved geometry. */
	public static function simple(key:String,
			painter:Canvas->Void,
			?style:LayoutStyle,
			?label:String,
			hitTestSelf:Bool = true,
			cachePolicy:CachePolicy = CachePolicy.None,
			?cacheKey:String):CanvasView {
		if (painter == null) throw "Simple canvas views require a painter";
		return new CanvasView(key, function(canvas, _) painter(canvas), style, label, hitTestSelf, cachePolicy,
			cacheKey);
	}

	/**
	 * Adds `handler` for events of `kind` on the region, and returns the view, for chaining. Throws without a kind or
	 * handler.
	 */
	public function on(kind:String, handler:UiEvent->Void):CanvasView {
		if (kind == null
			|| kind.length == 0 || handler == null) throw "Canvas view handlers require an event kind and callback";
		var values = handlers.get(kind);
		if (values == null) {
			values = [];
			handlers.set(kind, values);
		}
		values.push(handler);
		return this;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), function() {
			var nodeId = context.rootId("canvas");
			var node = context.styled(nodeId, LayoutVisualKind.Custom,
				new StyleIdentity("canvas", key, key, null, ["canvas"]), style);
			node.hitTestSelf = hitTestSelf;
			node.cachePolicy = cachePolicy;
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Group, label);
			node.onPaint(painter, cacheKey);
			for (kind in handlers.keys()) for (handler in handlers.get(kind)) node.on(kind, handler);
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
