package haxeon.ui.widgets.layout;
import haxeon.ui.widgets.KeyedView;

import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleTarget;

/** Vertical composition over a generic box render node. */
class Column implements View {
	final key:Key;
	final children:Array<KeyedView>;
	public final style:LayoutStyle;

	public function new(key:String, children:Array<KeyedView>, ?style:LayoutStyle) {
		this.key = new Key(key);
		this.children = children == null ? [] : children;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.style.direction = LayoutDirection.TopToBottom;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var id = context.id("column");
			var computed = context.resolveStyle(new StyleTarget("column", key.value, key.value,
				null, ["column"], context.interactionStates.get(id)), style);
			var node = new RenderNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			node.setStyleIdentity("column", key.value, key.value, null, ["column"]);
			node.states = context.interactionStates.get(id);
			node.computedStyle = computed;
			for (child in children)
				node.add(context.withStyleParent(computed, function() return child.build(context)));
			return node;
		});
	}
}
