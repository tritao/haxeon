package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Canvas;
import haxeon.ui.Image;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;

/** One image layer positioned by normalized view coordinates. */
class ImageLayer {
	/** The layer's image. */
	public final image:Image;

	/** Its left edge, as a fraction of the view's width. */
	public final x:Float;

	/** Its top edge, as a fraction of the view's height. */
	public final y:Float;

	/** Its width, as a fraction of the view's. */
	public final width:Float;

	/** Its height, as a fraction of the view's. */
	public final height:Float;

	/** How opaque it is, from 0 to 1. */
	public final opacity:Float;

	/** A layer drawing `image` over the given fraction of the view. */
	public function new(image:Image, x:Float, y:Float, width:Float, height:Float, opacity:Float = 1.0) {
		if (image == null || image.isDisposed() || x < 0.0 || y < 0.0 || width <= 0.0 || height <= 0.0 || opacity < 0.0
			|| opacity > 1.0) throw "Image layers require a live image, positive normalized bounds, and valid opacity";
		this.image = image;
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		this.opacity = opacity;
	}
}

/** Accessible retained composition of multiple image layers. */
class LayeredImageView implements View {
	/** Identifies the view among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The layers, bottom first. */
	public final layers:Array<ImageLayer>;

	/** Its accessible name; without one, assistive technology skips it. */
	public final label:Null<String>;

	/** The view's box. */
	public final style:LayoutStyle;

	/** A view drawing `layers` one over another. */
	public function new(key:String, layers:Array<ImageLayer>, ?label:String, ?style:LayoutStyle) {
		if (key == null || key.length == 0
			|| layers == null
			|| layers.length == 0) throw "Layered image views require a stable key and at least one layer";
		this.key = key;
		this.layers = layers.copy();
		this.label = label;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), () -> {
			var node = context.createNode(context.rootId("layered-image"), LayoutVisualKind.Custom, style);
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Image, label);
			node.onPaint((canvas:Canvas, geometry:ResolvedLayoutItem) -> {
				for (layer in layers) {
					canvas.withState(target -> {
						if (layer.opacity < 1.0) target.setAlpha(layer.opacity);
						target.drawImage(layer.image,
							new Rect(layer.x * geometry.width,
							layer.y * geometry.height,
							layer.width * geometry.width,
							layer.height * geometry.height));
					});
				}
			});
			return node;
		});
	}
}
