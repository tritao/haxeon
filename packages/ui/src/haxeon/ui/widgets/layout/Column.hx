package haxeon.ui.widgets.layout;
import haxeon.ui.widgets.KeyedView;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleTarget;

/** Vertical composition over a generic box render node. */
class Column implements View {
	final key:Key;
	final children:Array<KeyedView>;

	/** The column's box: its children laid out top to bottom, with its gap, padding and alignment. */
	public final style:LayoutStyle;

	/** A column of `children`, each keyed so its state survives reordering. */
	public function new(key:String, children:Array<KeyedView>, ?style:LayoutStyle) {
		this.key = new Key(key);
		this.children = children == null ? [] : children;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.style.direction = LayoutDirection.TopToBottom;
	}

	public function build(context:BuildContext):RenderNode {
		var id = context.withScope(key, function() return context.rootId("column"));
		return buildWithId(context, id);
	}

	/** Build with an ID already claimed by a self-updating owner. */
	public function buildWithId(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		return context.withScope(key, function() {
			var computed = context.resolveStyle(new StyleTarget("column", key.rawValue(), key.rawValue(), null,
				["column"], context.interactionStates.get(id)),
				style);
			var node = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			node.setStyleIdentity("column", key.rawValue(), key.rawValue(), null, ["column"]);
			node.states = context.interactionStates.get(id);
			node.computedStyle = computed;
			for (child in children) node.add(context.withStyleParent(computed, function() return child.build(context)));
			return node;
		});
	}
}
