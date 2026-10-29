package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Interaction flags a retained subtree actually rendered when it was built. */
class InteractionStateSnapshot {
	static final interactionMask:Int = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;

	final ids:Array<WidgetId>;
	final values:Array<Int>;
	/** Widgets left out because they restyle themselves, with the builds that do it, kept alive with the cached subtree. */
	final restyling:Array<WidgetId>;
	final restylingBuilds:Array<SelfUpdatingBuild>;

	public function new(root:RenderNode, context:BuildContext) {
		if (root == null)
			throw "Retained interaction snapshots require a render tree";
		ids = [];
		values = [];
		restyling = [];
		restylingBuilds = [];
		root.walk(function(node) {
			if (!(node.recordsInteraction || node.focusable || node.semantics != null))
				return;
			// A widget that restyles in place follows these changes itself, for its whole subtree.
			var owner = context.restylingOwner(node);
			if (owner != null) {
				if (owner == node) {
					restyling.push(node.id);
					restylingBuilds.push(cast context.restylingBuild(node));
				}
				return;
			}
			// Nodes that can own focus or semantics may start recording state only
			// after the first pointer or focus transition.
			ids.push(node.id);
			values.push(node.states & interactionMask);
		});
	}

	public function matches(context:BuildContext):Bool {
		for (index in 0...ids.length)
			if ((context.interactionStates.get(ids[index]) & interactionMask) != values[index])
				return false;
		for (index in 0...restyling.length)
			if (!context.rearmRestyling(restyling[index], restylingBuilds[index]))
				return false;
		return true;
	}
}
