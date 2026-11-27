package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Canvas;
import haxeon.ui.Image;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;

/** Accessible image view that records its draw in the node's custom display list. */
class ImageView implements View {
	/** Identifies the image among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The image shown. */
	public final image:Image;

	/** Its accessible name; without one, assistive technology skips it. */
	public final label:Null<String>;

	/** The image's box. */
	public final style:LayoutStyle;

	/** How the image fills its box. */
	public final fit:ImageFit;

	/** A view showing `image`. */
	public function new(key:String, image:Image, ?label:String, ?style:LayoutStyle, fit:ImageFit = ImageFit.Stretch) {
		if (key == null || key.length == 0
			|| image == null || image.isDisposed()) throw "Image views require a stable key and live image";
		this.key = key;
		this.image = image;
		this.label = label;
		if (style == null) {
			this.style = new LayoutStyle();
			this.style.width = LayoutAxis.fixed(image.width);
			this.style.height = LayoutAxis.fixed(image.height);
		} else this.style = style.copy();
		this.fit = fit;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), function() {
			var nodeId = context.rootId("image");
			var identity = new StyleIdentity("image", key, key, null, ["image"]);
			var computed = context.resolveStyled(nodeId, identity, style);
			var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			context.applyStyled(node, identity, computed);
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Image, label);
			node.onPaint(function(canvas:Canvas, geometry:ResolvedLayoutItem) {
				if (image.isDisposed() || geometry.width <= 0.0 || geometry.height <= 0.0) return;
				var scale = switch fit {
					case ImageFit.Contain:
						Math.min(geometry.width / image.width, geometry.height / image.height);
					case ImageFit.Cover:
						Math.max(geometry.width / image.width, geometry.height / image.height);
					case ImageFit.None:
						1.0;
					case ImageFit.Stretch:
						0.0;
				};
				if (fit == ImageFit.Stretch) {
					canvas.drawImage(image, new Rect(0.0, 0.0, geometry.width, geometry.height));
					return;
				}
				var width = image.width * scale;
				var height = image.height * scale;
				var destination = new Rect((geometry.width - width) * 0.5, (geometry.height - height) * 0.5, width,
					height);
				canvas.withClip(new Rect(0.0, 0.0, geometry.width, geometry.height),
					function(target) target.drawImage(image, destination));
			});
			return node;
		});
	}
}

/** Controls how an image's intrinsic aspect ratio maps into its view bounds. */
enum ImageFit implements Hashable {
	/** Fills the box, distorting the image if the shapes differ. */
	Stretch;
	/** The largest size that fits whole, keeping the shape; the rest of the box is empty. */
	Contain;
	/** The smallest size that fills the box, keeping the shape; the overflow is cut off. */
	Cover;
	/** The image's own size, centered. */
	None;
}
