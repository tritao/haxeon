package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Interaction flags a retained subtree actually rendered when it was built. */
class InteractionStateSnapshot {
	static final interactionMask:Int = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;

	final ids:Array<WidgetId>;
	final values:Array<Int>;

	public function new(root:RenderNode) {
		if (root == null)
			throw "Retained interaction snapshots require a render tree";
		ids = [];
		values = [];
		root.walk(function(node) {
			// Nodes that can own focus or semantics may start recording state only
			// after the first pointer or focus transition.
			if (node.recordsInteraction || node.focusable || node.semantics != null) {
				ids.push(node.id);
				values.push(node.states & interactionMask);
			}
		});
	}

	public function matches(context:BuildContext):Bool {
		for (index in 0...ids.length)
			if ((context.interactionStates.get(ids[index]) & interactionMask) != values[index])
				return false;
		return true;
	}
}
