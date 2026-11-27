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

/** Constrains a child's allocated width and height. */
class SizedBox implements View {
	final key:Key;
	final child:View;

	/** The box, with the width and height given. */
	public final style:LayoutStyle;

	/** `child` sized by `width` and `height`; an axis left out fits the child. */
	public function new(key:String, child:View, ?width:LayoutAxis, ?height:LayoutAxis) {
		if (child == null) throw "SizedBox requires a child view";
		this.key = new Key(key);
		this.child = child;
		style = new LayoutStyle();
		style.width = width == null ? LayoutAxis.grow() : width;
		style.height = height == null ? LayoutAxis.fit() : height;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, function() {
			var id = context.rootId("sized-box");
			var node = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("sized-box", key.rawValue, key.rawValue, null, ["sized-box"]), style);
			var computed = node.computedStyle;
			var content = context.withStyleParent(computed, function() {
				return context.withScope(new Key("content"), function() return child.build(context));
			});
			node.add(content);
			return node;
		});
	}
}
