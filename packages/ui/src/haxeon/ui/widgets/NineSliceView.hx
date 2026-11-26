package haxeon.ui.widgets;

import haxeon.ui.Image;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutNode;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.ComputedStyle;

/** Accessible image view that preserves four edge insets while stretching its center. */
class NineSliceView implements View {
	/** Identifies the view among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The image sliced. */
	public final image:Image;

	/** Its accessible name; without one, assistive technology skips it. */
	public final label:Null<String>;

	/** The view's box. */
	public final style:LayoutStyle;

	/** The width of the left edge kept unstretched, in image pixels. */
	public final left:Float;

	/** The height of the top edge kept unstretched. */
	public final top:Float;

	/** The width of the right edge kept unstretched. */
	public final right:Float;

	/** The height of the bottom edge kept unstretched. */
	public final bottom:Float;

	/** `image` stretched to the box, its corners kept and its edges stretched along their length only. */
	public function new(key:String,
			image:Image,
			left:Float,
			top:Float,
			right:Float,
			bottom:Float,
			?label:String,
			?style:LayoutStyle) {
		if (key == null || key.length == 0 || image == null || image.isDisposed() || left < 0.0 || top < 0.0
			|| right < 0.0
			|| bottom < 0.0) throw "Nine-slice views require a stable key, live image, and non-negative insets";
		this.key = key;
		this.image = image;
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
		this.label = label;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var nodeId = context.rootId("nine-slice");
			var computed = context.resolveStyle(context.styleTarget(nodeId, "nine-slice", key, key, null,
				["nine-slice"]),
				style);
			var resolvedDecorations = computed.getDecorations();
			var decorationSource = computed.source(StyleProperty.Decorations);
			if ((resolvedDecorations == null || resolvedDecorations.decorations.length == 0)
				&& decorationSource != null && decorationSource.stylesheet == "framework"
				&& decorationSource.selector == "default")
				computed.setDecorations(DecorationChain.of([new NineSliceDecoration(image, left, top, right, bottom)]),
					new StyleSource("framework", "nine-slice", -1, "default"));
			var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			node.setStyleIdentity("nine-slice", key, key, null, ["nine-slice"]);
			node.states = context.interactionStates.peek(nodeId);
			node.computedStyle = computed;
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Image, label);
			return node;
		});
	}
}
