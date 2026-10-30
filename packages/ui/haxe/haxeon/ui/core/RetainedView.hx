package haxeon.ui.core;

/**
 * Reuses a render subtree while nothing it was built from changed: widget state and interaction inside it, reads recorded with
 * BuildContext.observeInt and friends, and the optional application-owned revision key. Prefer observing what the builder reads
 * to a hand-written key: the read itself records the dependency, so it cannot be left out.
 */
class RetainedView implements View {
	final builder:BuildContext->View;
	final key:String;
	final revision:Null<Void->String>;
	/** Single-threaded scratch: filled and read within one `build`, before the view's own children build. */
	static final scratchKey:KeyHash = new KeyHash();

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
		var hash = scratchKey.reset().addString(revisionBuilder == null ? "" : revisionBuilder())
			.addInt(context.styleRevision).addFloat(context.viewportWidth).addFloat(context.viewportHeight);
		var keyA = hash.a, keyB = hash.b;
		var cached = cache.entry;
		if (cached != null && !context.bypassRetention && cached.matches(keyA, keyB) && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			context.retainObserved(cached.observed);
			var retained = context.currentRoot(cached.root);
			cached.replaceRoot(retained);
			context.claimRetainedTree(retained);
			retained.detach();
			return retained;
		}
		if (cached != null)
			cached.root.detach();
		var marker = context.stateUsageMarker();
		var intMark = context.observedIntMarker(), stringMark = context.observedStringMarker();
		var view = builder(context);
		if (view == null)
			throw 'Retained view "$key" returned no view';
		var root = view.build(context);
		var usedStates = context.stateIdsUsedSince(marker);
		cache.replace(keyA, keyB, root, usedStates, context.stateRevisions(usedStates),
			new InteractionStateSnapshot(context.currentRoot(root), context), context.observedSince(intMark, stringMark));
		return root;
	}
}

private class RetainedViewCache {
	public var entry(default, null):Null<RetainedViewEntry>;

	public function new()
		entry = null;

	public function replace(keyA:Int, keyB:Int, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>,
			interactions:InteractionStateSnapshot, observed:Dependencies):Void {
		if (entry != null && entry.root != root)
			entry.root.detach();
		entry = new RetainedViewEntry(keyA, keyB, root, stateIds, stateRevisions, interactions, observed);
	}

	public function dispose():Void {
		if (entry != null)
			entry.root.detach();
		entry = null;
	}
}

private class RetainedViewEntry {
	final keyA:Int;
	final keyB:Int;
	public var root(default, null):RenderNode;
	public final stateIds:Array<Int>;
	final stateRevisions:Array<Int>;
	final interactions:InteractionStateSnapshot;
	/** What the subtree's build read outside widget state (BuildContext.observeInt and friends). */
	public final observed:Dependencies;

	public function new(keyA:Int, keyB:Int, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>,
		interactions:InteractionStateSnapshot, observed:Dependencies) {
		this.keyA = keyA;
		this.keyB = keyB;
		this.root = root;
		this.stateIds = stateIds == null ? [] : stateIds.copy();
		this.stateRevisions = stateRevisions == null ? [] : stateRevisions.copy();
		this.interactions = interactions;
		this.observed = observed;
	}

	public function matches(otherA:Int, otherB:Int):Bool
		return keyA == otherA && keyB == otherB;

	/** A self-updating widget at the root of the subtree was rebuilt in place; keep the replacement. */
	public function replaceRoot(next:RenderNode):Void
		root = next;

	public function statesMatch(context:BuildContext):Bool {
		// See DockPanelCacheEntry: a widget inside changed its own state, so the built tree is stale.
		var current = context.stateRevisions(stateIds);
		for (index in 0...current.length)
			if (current[index] != stateRevisions[index])
				return false;
		return interactions.matches(context) && observed.current();
	}
}
