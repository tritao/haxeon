package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Interaction flags a retained subtree actually rendered when it was built. */
class InteractionStateSnapshot {
	static final interactionMask:Int = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;

	static final NoIds:Array<WidgetId> = [];
	static final NoValues:Array<Int> = [];
	static final NoBuilds:Array<SelfUpdatingBuild> = [];

	var ids:Array<WidgetId>;
	var values:Array<Int>;
	/** Per node, the flags its build depends on: Hovered drops out where no hover rule matches (BuildContext.hoverRebuilds). */
	var masks:Array<Int>;
	/** Widgets left out because they update themselves, with the builds that do it, kept alive with the cached subtree. */
	var updatingBuilds:Array<SelfUpdatingBuild>;
	var updatingRevisions:Array<Int>;

	public function new(root:RenderNode, context:BuildContext, ?boundary:RenderNode) {
		if (root == null)
			throw "Retained interaction snapshots require a render tree";
		ids = NoIds;
		values = NoValues;
		masks = NoValues;
		updatingBuilds = NoBuilds;
		updatingRevisions = NoValues;
		capture(root, context, boundary);
	}

	function capture(node:RenderNode, context:BuildContext, boundary:Null<RenderNode>):Void {
		if (node != boundary) {
			// A composite updater keeps its current descendants; enclosing caches stop at that mutable boundary.
			var build = context.updatingBuild(node);
			if (build != null) {
				if (updatingBuilds.length == 0) {updatingBuilds = []; updatingRevisions = [];}
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
				if (ids.length == 0) {ids = []; values = []; masks = [];}
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

	public function appendStateIds(ids:Null<Array<Int>>, ?previous:Array<Int>):Null<Array<Int>> {
		var count = ids == null ? 0 : ids.length;
		for (entry in updatingBuilds) {
			var dependencies = entry.dependencies;
			if (dependencies != null && dependencies.allStateIds != null) count += dependencies.allStateIds.length;
		}
		if (count == 0) return ids;
		var result:Null<Array<Int>> = null, position = 0;
		if (previous == null || previous.length != count) {result = []; result.resize(count);}
		for (group in 0...updatingBuilds.length + 1) {
			var dependencies = group == 0 ? null : updatingBuilds[group - 1].dependencies;
			var source = group == 0 ? ids : dependencies == null ? null : dependencies.allStateIds;
			if (source == null) continue;
			for (id in source) {
				if (result == null && previous[position] != id) {
					result = []; result.resize(count);
					for (index in 0...position) result[index] = previous[index];
				}
				if (result != null) result[position] = id;
				position++;
			}
		}
		return result == null ? previous : result;
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
