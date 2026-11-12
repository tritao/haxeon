package haxeon.ui.core;

/** Retains a bounded set of explicitly keyed alternatives under one stable parent. */
class RetainedVariants implements View {
	final key:String;
	final variant:String;
	final builder:BuildContext->View;
	final revision:Null<Void->String>;
	final capacity:Int;
	final resetChangedOnReturn:Bool;
	static final scratch:KeyHash = new KeyHash();

	public function new(key:String, variant:String, builder:BuildContext->View,
			?revision:Void->String, capacity:Int = 4, resetChangedOnReturn:Bool = false) {
		if (key == null || key.length == 0 || variant == null || builder == null || capacity < 1)
			throw "Retained variants require a stable key, a variant, a builder, and positive capacity";
		this.key = key;
		this.variant = variant;
		this.builder = builder;
		this.revision = revision;
		this.capacity = capacity;
		this.resetChangedOnReturn = resetChangedOnReturn;
	}

	public function build(context:BuildContext):RenderNode {
		var state:State<RetainedVariantsCache> = context.resourceState(context.id("retained-variants:" + key),
			function() return new RetainedVariantsCache(key, capacity), function(cache) cache.dispose());
		var cache = state.value;
		cache.setCapacity(capacity);
		cache.retain(context);
		var getRevision = revision;
		// Read user code before touching the shared hash scratch; it may build another retained view.
		var revisionValue = getRevision == null ? "" : getRevision();
		var hash = scratch.reset().addString(revisionValue)
			.addInt(context.styleRevision).addFloat(context.viewportWidth).addFloat(context.viewportHeight);
		var keyA = hash.a, keyB = hash.b;
		var entry = cache.get(variant);
		var returning = cache.active != null && cache.active != variant;
		if (entry != null && !context.bypassRetention && entry.matches(keyA, keyB, context,
				returning && resetChangedOnReturn)) {
			cache.active = variant;
			context.retainStateIds(entry.refreshStateIds());
			var retained = entry.currentRoot();
			context.retainDependencies(entry.observed);
			entry.root = retained;
			context.claimRetainedTree(retained);
			retained.detach();
			return retained;
		}
		if (entry != null) entry.root.detach();
		var scope = entry != null && !(returning && resetChangedOnReturn) ? entry.scope : cache.newScope(variant);
		var dirty = entry != null && scope == entry.scope &&
			(entry.dirty || (resetChangedOnReturn && entry.interactions.buildsChanged()));
		var stateMark = context.stateUsageMarker();
		var dependencyMark = context.dependencyMarker();
		var root = context.withScope(new Key(scope), function() {
			var view = builder(context);
			if (view == null) throw 'Retained variant "$variant" returned no view';
			return view.build(context);
		});
		var used = context.stateIdsUsedSince(stateMark);
		var interactions = new InteractionStateSnapshot(context.currentRoot(root), context, null, resetChangedOnReturn);
		var observed = context.dependenciesSince(dependencyMark,
			entry == null ? null : entry.observed);
		cache.put(variant, new RetainedVariantEntry(keyA, keyB, scope, root, used, interactions,
			observed, context, dirty, entry == null ? null : entry.stateIds));
		cache.active = variant;
		return root;
	}
}

private class RetainedVariantsCache {
	final entries:Map<String, RetainedVariantEntry> = new Map();
	final recent:Array<String> = [];
	var capacity:Int;
	final key:String;
	var nextScope:Int = 0;
	public var active:Null<String> = null;
	public function new(key:String, capacity:Int) { this.key = key; this.capacity = capacity; }
	public function newScope(variant:String):String
		return "variant:" + key.length + ":" + key + ":" + variant.length + ":" + variant + ":" + nextScope++;
	public function setCapacity(value:Int):Void { capacity = value; trim(); }
	public function get(key:String):Null<RetainedVariantEntry> {
		var entry = entries.get(key);
		if (entry != null) { recent.remove(key); recent.push(key); }
		return entry;
	}
	public function put(key:String, entry:RetainedVariantEntry):Void {
		var previous = entries.get(key);
		if (previous != null && previous != entry) {
			if (previous.root != entry.root) previous.root.detach();
			if (previous.observed != entry.observed) previous.observed.dispose();
			previous.interactions.dispose();
		}
		entries.set(key, entry);
		recent.remove(key); recent.push(key); trim();
	}
	function trim():Void {
		while (recent.length > capacity) {
			var oldest = recent.shift();
			if (oldest != null) {
				var entry = entries.get(oldest);
				entries.remove(oldest);
				// The root may still be the submitted prior for this frame; only release the cache's subscriptions now.
				if (entry != null) { entry.observed.dispose(); entry.interactions.dispose(); }
			}
		}
	}
	public function retain(context:BuildContext):Void {
		for (entry in entries)
			context.retainStateIds(entry.refreshStateIds(), true);
	}
	public function dispose():Void {
		for (entry in entries) entry.dispose();
		entries.clear(); recent.resize(0);
	}
}

private class RetainedVariantEntry {
	final keyA:Int;
	final keyB:Int;
	public final scope:String;
	public var root:RenderNode;
	public var stateIds(default, null):Array<Int>;
	final usedStateIds:Array<Int>;
	public final interactions:InteractionStateSnapshot;
	public final observed:Dependencies;
	public final dirty:Bool;
	final rootScope:Null<RenderScope>;
	final nodes:Array<RenderNode> = [];
	final parents:Array<Null<RenderNode>> = [];
	final positions:Array<Int> = [];
	final childCounts:Array<Int> = [];

	public function new(keyA:Int, keyB:Int, scope:String, root:RenderNode, ids:Array<Int>,
			interactions:InteractionStateSnapshot, observed:Dependencies, context:BuildContext, dirty:Bool,
			previousStateIds:Null<Array<Int>>) {
		this.keyA = keyA; this.keyB = keyB; this.scope = scope; this.root = root;
		rootScope = context.retainedRootScope(root);
		usedStateIds = ids == null ? [] : ids.copy();
		this.interactions = interactions; this.observed = observed; this.dirty = dirty;
		stateIds = interactions.appendStateIds(usedStateIds, previousStateIds);
		capture(root, context, false);
	}

	/** Nested self-updating widgets may replace resource IDs while this variant stays cached. */
	public function refreshStateIds():Array<Int> {
		stateIds = interactions.appendStateIds(usedStateIds, stateIds);
		return stateIds;
	}

	function capture(node:RenderNode, context:BuildContext, variableParent:Bool):Void {
		var parent = node == root ? null : node.parent;
		nodes.push(node); parents.push(parent);
		positions.push(parent == null ? -1 : variableParent ? -2 : parent.children.indexOf(node));
		var owner = node == root ? null : context.updatingBuild(node);
		var native = context.renderScopeAt(node);
		childCounts.push(owner == null && native == null ? node.children.length : -1);
		for (child in node.children) {
			var owned = native != null && native.owns(child);
			if (owner != null && owner.built != null)
				for (made in owner.built.children) if (made.id.value == child.id.value) { owned = true; break; }
			if (!owned) capture(child, context, owner != null || native != null);
		}
	}

	public function currentRoot():RenderNode
		return rootScope == null ? root : rootScope.root;

	function topologyMatches():Bool {
		if (RenderNode.latest(root) != root) return false;
		var rootOwner = rootScope;
		if (rootOwner != null) {
			var current = rootOwner.root;
			if (!current.id.equals(root.id)) return false;
			root = current;
		}
		for (index in 0...nodes.length) {
			var oldNode = nodes[index], native = index == 0 ? rootScope : oldNode.scopeOwner();
			if (native != null) {
				var current = index == 0 ? native.root : native.currentRoot(oldNode);
				if (!current.id.equals(oldNode.id)) return false;
				nodes[index] = current;
			}
			var oldParent = parents[index];
			if (oldParent != null) {
				var nativeParent = oldParent.scopeOwner();
				if (nativeParent != null) {
					var current = nativeParent.currentRoot(oldParent);
					if (!current.id.equals(oldParent.id)) return false;
					parents[index] = current;
				}
			}

			var node = nodes[index], parent = parents[index], position = positions[index];
			if (childCounts[index] >= 0 && node.children.length != childCounts[index]) return false;
			if (node != root && position == -2 && (node.parent != parent || parent == null || parent.children.indexOf(node) < 0)) return false;
			if (node != root && position != -2 && (node.parent != parent || parent == null || position < 0 ||
					position >= parent.children.length || parent.children[position] != node)) return false;
		}
		return true;
	}

	public function matches(a:Int, b:Int, context:BuildContext, strict:Bool):Bool
		return keyA == a && keyB == b && topologyMatches() && (!strict || (!dirty && !interactions.buildsChanged())) &&
			observed.current() && interactions.matches(context);

	public function dispose():Void {
		root.detach();
		interactions.dispose();
		observed.dispose();
	}
}
