package haxeon.ui.widgets.layout;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;
import haxeon.ui.widgets.KeyedView;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Horizontal composition over a generic box render node. */
class Row implements View {
	final key:Key;
	final children:Array<KeyedView>;

	/** The row's box: its children laid out left to right, with its gap, padding and alignment. */
	public final style:LayoutStyle;

	/** A row of `children`, each keyed so its state survives reordering. */
	public function new(key:String, children:Array<KeyedView>, ?style:LayoutStyle) {
		this.key = new Key(key);
		this.children = children == null ? [] : children;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.style.direction = LayoutDirection.LeftToRight;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, () -> {
			var id = context.rootId("row");
			var node = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("row", key.rawValue, key.rawValue, null, ["row"]), style);
			var computed = node.computedStyle;
			for (child in children) node.add(context.withStyleParent(computed, () -> child.build(context)));
			return node;
		});
	}
}
