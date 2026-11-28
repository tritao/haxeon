package haxeon.ui.widgets.layout;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Insets;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Adds layout-engine padding around one child view. */
class Padding implements View {
	final key:Key;
	final child:View;
	final insets:Insets;

	/** The box, with the padding set. */
	public final style:LayoutStyle;

	/** `child` with `insets` of space around it. */
	public function new(key:String, child:View, ?insets:Insets, ?style:LayoutStyle) {
		if (child == null) throw "Padding requires a child view";
		this.key = new Key(key);
		this.child = child;
		this.insets = insets == null ? new Insets(0.0, 0.0, 0.0, 0.0) : insets;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.style.padding = this.insets;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, () -> {
			var id = context.rootId("padding");
			var node = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("padding", key.rawValue, key.rawValue, null, ["padding"]), style);
			var computed = node.computedStyle;
			var content = context.withStyleParent(computed, () -> {
				return context.withScope(new Key("content"), () -> child.build(context));
			});
			node.add(content);
			return node;
		});
	}
}
