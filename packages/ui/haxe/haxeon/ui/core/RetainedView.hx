package haxeon.ui.core;

/**
 * Reuses a render subtree while its tracked signals, Observable fields and interaction state remain current.
 */
class RetainedView implements View {
  final builder:BuildContext -> View;
  final key:String;
  final revision:Null<Void -> String>;
  /** Single-threaded scratch: filled and read within one `build`, before the view's own children build. */
  static final scratchKey:KeyHash = new KeyHash();

  public function new(key:String, builder:BuildContext -> View, ?revision:Void -> String) {
    if (key == null || key.length == 0 || builder == null) throw "Retained views require a stable key and builder";
    this.key = key;
    this.builder = builder;
    this.revision = revision;
  }

  public function build(context:BuildContext):RenderNode {
    var factory:Void -> RetainedViewCache = function() return new RetainedViewCache();
    var disposer:RetainedViewCache -> Void = function(value) value.dispose();
    var cacheState:State<RetainedViewCache> = context.resourceState(
      context.id("retained-view-cache:" + key),
      factory,
      disposer
    );
    var cache = cacheState.value;
    var revisionBuilder:Null<Void -> String> = revision;
    var hash = scratchKey.reset().addString(revisionBuilder == null ? "" : revisionBuilder())
      .addInt(context.styleRevision).addFloat(context.viewportWidth).addFloat(context.viewportHeight);
    var keyA = hash.a, keyB = hash.b;
    var cached = cache.entry;
    if (cached != null && !context.bypassRetention && cached.matches(keyA, keyB) && cached.statesMatch(context)) {
      context.retainStateIds(cached.refreshStateIds());
      var retained = context.currentRoot(cached.root);
      context.retainDependencies(cached.observed);
      cached.replaceRoot(retained);
      context.claimRetainedTree(retained);
      retained.detach();
      return retained;
    }
    if (cached != null) cached.root.detach();
    var marker = context.stateUsageMarker();
    var dependencyMark = context.dependencyMarker();
    var view = builder(context);
    if (view == null) throw 'Retained view "$key" returned no view';
    var root = view.build(context);
    var usedStates = context.stateIdsUsedSince(marker);
    var interactions = new InteractionStateSnapshot(context.currentRoot(root), context);
    var observed = context.dependenciesSince(dependencyMark, cached == null ? null : cached.observed);
    cache.replace(keyA, keyB, root, usedStates, interactions, observed, cached == null ? null : cached.stateIds);
    return root;
  }
}

private class RetainedViewCache {
  public var entry(default, null):Null<RetainedViewEntry>;

  public function new() entry = null;

  public function replace(
    keyA:Int,
    keyB:Int,
    root:RenderNode,
    usedStates:Null<Array<ResourceId>>,
    interactions:InteractionStateSnapshot,
    observed:Dependencies,
    previousStates:Null<Array<ResourceId>>
  ):Void {
    var previous = entry;
    if (previous != null) {
      if (previous.root != root) previous.root.detach();
      previous.interactions.dispose();
    }
    entry = new RetainedViewEntry(keyA, keyB, root, usedStates, interactions, observed, previousStates);
  }

  public function dispose():Void {
    if (entry != null) entry.dispose();
    entry = null;
  }
}

private class RetainedViewEntry {
  final keyA:Int;
  final keyB:Int;
  public var root(default, null):RenderNode;
  public var stateIds(default, null):Array<ResourceId>;
  final usedStates:Array<ResourceId>;
  public final interactions:InteractionStateSnapshot;
  /** Signal and Observable fields read while building the subtree. */
  public final observed:Dependencies;

  public function new(
    keyA:Int,
    keyB:Int,
    root:RenderNode,
    usedStates:Null<Array<ResourceId>>,
    interactions:InteractionStateSnapshot,
    observed:Dependencies,
    previousStates:Null<Array<ResourceId>>
  ) {
    this.keyA = keyA;
    this.keyB = keyB;
    this.root = root;
    this.usedStates = usedStates == null ? [] : usedStates.copy();
    this.interactions = interactions;
    this.observed = observed;
    stateIds = interactions.appendStateIds(this.usedStates, previousStates);
  }

  public function matches(otherA:Int, otherB:Int):Bool return keyA == otherA && keyB == otherB;

  /** A self-updating widget at the root of the subtree was rebuilt in place; keep the replacement. */
  public function replaceRoot(next:RenderNode):Void root = next;

  /** Nested self-updating widgets may replace resource state IDs without rebuilding this cache entry. */
  public function refreshStateIds():Array<ResourceId> {
    stateIds = interactions.appendStateIds(usedStates, stateIds);
    return stateIds;
  }

  public function statesMatch(context:BuildContext):Bool {
    return observed.current() && interactions.matches(context);
  }

  public function dispose():Void {
    root.detach();
    interactions.dispose();
    observed.dispose();
  }
}
