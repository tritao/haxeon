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
	final updatingBuilds:Array<SelfUpdatingBuild>;
	final updatingRevisions:Array<Int>;

	public function new(root:RenderNode, context:BuildContext, ?boundary:RenderNode) {
		if (root == null)
			throw "Retained interaction snapshots require a render tree";
		ids = [];
		values = [];
		masks = [];
		updatingBuilds = [];
		updatingRevisions = [];
		capture(root, context, boundary);
	}

	function capture(node:RenderNode, context:BuildContext, boundary:Null<RenderNode>):Void {
		if (node != boundary) {
			// A composite updater keeps its current descendants; enclosing caches stop at that mutable boundary.
			var build = context.updatingBuild(node);
			if (build != null) {
				updatingBuilds.push(build);
				var dependencies = build.dependencies;
				updatingRevisions.push(dependencies == null ? 0 : dependencies.stateInvalidationRevision);
				// Callers can append independently updating views after the owner's build was captured.
				var built = build.built;
				for (child in node.children) {
					var owned = false;
					if (built != null)
						for (made in built.children) if (made.id.value == child.id.value) {owned = true; break;}
					if (!owned) capture(child, context, boundary);
				}
				return;
			}
			if (node.recordsInteraction && context.updatingOwner(node) == null) {
				var mask = interactionMask;
				if (!context.hoverRebuilds(node)) mask &= ~StyleState.Hovered;
				ids.push(node.id);
				masks.push(mask);
				values.push(node.states & mask);
			}
		}
		for (child in node.children) capture(child, context, boundary);
	}

	public function statesChanged(context:BuildContext):Bool {
		for (index in 0...updatingBuilds.length) {
			var entry = updatingBuilds[index], dependencies = entry.dependencies;
			if ((dependencies == null ? 0 : dependencies.stateInvalidationRevision) != updatingRevisions[index]
				|| context.updatingStatesChanged(entry)) return true;
		}
		return false;
	}

	public function appendStateIds(ids:Null<Array<Int>>):Null<Array<Int>> {
		var result = ids;
		for (entry in updatingBuilds) {
			var dependencies = entry.dependencies;
			if (dependencies == null || dependencies.allStateIds == null) continue;
			if (result == ids) result = ids == null ? [] : ids.copy();
			for (id in dependencies.allStateIds) result.push(id);
		}
		return result;
	}

	public function retainState(context:BuildContext):Void {
		for (entry in updatingBuilds) context.retainUpdatingState(entry);
	}

	public function matches(context:BuildContext):Bool {
		if (statesChanged(context)) return false;
		for (index in 0...ids.length)
			if ((context.interactionStates.get(ids[index]) & masks[index]) != values[index])
				return false;
		for (entry in updatingBuilds) {
			var root = entry.root;
			if (root == null || !context.rearm(root.id, entry)) return false;
		}
		return true;
	}
}
