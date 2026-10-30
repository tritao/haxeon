package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Interaction flags a retained subtree actually rendered when it was built. */
class InteractionStateSnapshot {
	static final interactionMask:Int = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;

	final ids:Array<WidgetId>;
	final values:Array<Int>;
	/** Per node, the flags its build depends on: Hovered drops out where no hover rule matches (BuildContext.hoverRebuilds). */
	final masks:Array<Int>;
	/** Widgets left out because they update themselves, with the builds that do it, kept alive with the cached subtree. */
	final updating:Array<WidgetId>;
	final updatingBuilds:Array<SelfUpdatingBuild>;

	public function new(root:RenderNode, context:BuildContext) {
		if (root == null)
			throw "Retained interaction snapshots require a render tree";
		ids = [];
		values = [];
		masks = [];
		updating = [];
		updatingBuilds = [];
		root.walk(function(node) {
			// Only a node a widget built from interaction state can be stale; routing alone leaves states on others.
			if (!node.recordsInteraction)
				return;
			// A widget that updates itself follows these changes itself, for its whole subtree.
			var owner = context.updatingOwner(node);
			if (owner != null) {
				if (owner == node) {
					updating.push(node.id);
					updatingBuilds.push(cast context.updatingBuild(node));
				}
				return;
			}
			var mask = interactionMask;
			if (!context.hoverRebuilds(node))
				mask &= ~StyleState.Hovered;
			ids.push(node.id);
			masks.push(mask);
			values.push(node.states & mask);
		});
	}

	public function matches(context:BuildContext):Bool {
		for (index in 0...ids.length)
			if ((context.interactionStates.get(ids[index]) & masks[index]) != values[index])
				return false;
		for (index in 0...updating.length)
			if (!context.rearm(updating[index], updatingBuilds[index]))
				return false;
		return true;
	}
}
