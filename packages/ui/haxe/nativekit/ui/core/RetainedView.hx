package nativekit.ui.core;

import nativekit.ui.style.StyleState;

/** Reuses a stable render subtree while an application-owned revision key is unchanged. */
class RetainedView implements View {
	final builder:BuildContext->View;
	final key:String;
	final revision:Null<Void->String>;

	public function new(key:String, builder:BuildContext->View,
		?revision:Void->String) {
		if (key == null || key.length == 0 || builder == null)
			throw "Retained views require a stable key and builder";
		this.key = key;
		this.builder = builder;
		this.revision = revision;
	}

	public function build(context:BuildContext):RenderNode {
		var factory:Void->RetainedViewCache = function() return new RetainedViewCache();
		var disposer:RetainedViewCache->Void = function(value) value.dispose();
		var cacheState:State<RetainedViewCache> = context.resourceState(
			context.id("retained-view-cache:" + key), factory, disposer);
		var cache = cacheState.value;
		var revisionBuilder:Null<Void->String> = revision;
		var cacheKey = revisionBuilder == null ? "" : revisionBuilder();
		cacheKey += "|style=" + context.styleRevision +
			"|viewport=" + context.viewportWidth + "x" + context.viewportHeight;
		var cached = cache.entry;
		if (cached != null && cached.key == cacheKey && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			var retained = context.currentRoot(cached.root);
			cached.replaceRoot(retained);
			context.claimRetainedTree(retained);
			retained.detach();
			return retained;
		}
		if (cached != null)
			cached.root.detach();
		var marker = context.stateUsageMarker();
		var view = builder(context);
		if (view == null)
			throw 'Retained view "$key" returned no view';
		var root = view.build(context);
		var usedStates = context.stateIdsUsedSince(marker);
		cache.replace(cacheKey, root, usedStates, context.stateRevisions(usedStates));
		return root;
	}
}

private class RetainedViewCache {
	public var entry(default, null):Null<RetainedViewEntry>;

	public function new()
		entry = null;

	public function replace(key:String, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>):Void {
		if (entry != null && entry.root != root)
			entry.root.detach();
		entry = new RetainedViewEntry(key, root, stateIds, stateRevisions);
	}

	public function dispose():Void {
		if (entry != null)
			entry.root.detach();
		entry = null;
	}
}

private class RetainedViewEntry {
	public final key:String;
	public var root(default, null):RenderNode;
	public final stateIds:Array<Int>;
	final stateRevisions:Array<Int>;

	public function new(key:String, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>) {
		this.key = key;
		this.root = root;
		this.stateIds = stateIds == null ? [] : stateIds.copy();
		this.stateRevisions = stateRevisions == null ? [] : stateRevisions.copy();
	}

	/** A self-updating widget at the root of the subtree was rebuilt in place; keep the replacement. */
	public function replaceRoot(next:RenderNode):Void
		root = next;

	public function statesMatch(context:BuildContext):Bool {
		// See DockPanelCacheEntry: a widget inside changed its own state, so the built tree is stale.
		var current = context.stateRevisions(stateIds);
		for (index in 0...current.length)
			if (current[index] != stateRevisions[index])
				return false;
		var mask = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;
		var result = true;
		context.currentRoot(root).walk(function(node) {
			if (node.recordsInteraction && (node.states & mask) != (context.interactionStates.get(node.id) & mask))
				result = false;
		});
		return result;
	}
}
