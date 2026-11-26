package haxeon.ui.widgets.layout;
import haxeon.ui.widgets.KeyedView;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleTarget;

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

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var id = context.rootId("row");
			var computed = context.resolveStyle(new StyleTarget("row", key.rawValue, key.rawValue, null, ["row"],
				context.interactionStates.get(id)),
				style);
			var node = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			node.setStyleIdentity("row", key.rawValue, key.rawValue, null, ["row"]);
			node.states = context.interactionStates.get(id);
			node.computedStyle = computed;
			for (child in children) node.add(context.withStyleParent(computed, function() return child.build(context)));
			return node;
		});
	}
}
