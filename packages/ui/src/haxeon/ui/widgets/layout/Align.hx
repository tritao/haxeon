package haxeon.ui.widgets.layout;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Places a child within its allocated box using NativeUI's axis alignment. */
class Align implements View {
	final key:Key;
	final child:View;

	/** The box `child` is placed in. */
	public final style:LayoutStyle;

	/** `child` placed by `alignmentX` and `alignmentY` within the box, centered by default. Throws without a child. */
	public function new(key:String,
			child:View,
			alignmentX:LayoutAlignmentX = LayoutAlignmentX.Center,
			alignmentY:LayoutAlignmentY = LayoutAlignmentY.Center,
			?style:LayoutStyle) {
		if (child == null) throw "Align requires a child view";
		this.key = new Key(key);
		this.child = child;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.childAlignX = alignmentX;
		this.style.childAlignY = alignmentY;
		// Alignment covers the cross axis; center the child on the main axis too
		// so this widget keeps its two-dimensional centering contract for both
		// row and column parents.
		this.style.childDistribution = LayoutDistribution.Center;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, () -> {
			var id = context.rootId("align");
			var node = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("align", key.rawValue, key.rawValue, null, ["align"]), style);
			var computed = node.computedStyle;
			var content = context.withStyleParent(computed, () -> {
				return context.withScope(new Key("content"), () -> child.build(context));
			});
			node.add(content);
			return node;
		});
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.grow();
		return result;
	}
}
