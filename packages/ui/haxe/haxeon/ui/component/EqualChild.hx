package haxeon.ui.component;

import Equatable;
import haxeon.ui.core.ResourceId;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Dependencies;
import haxeon.ui.core.InteractionStateSnapshot;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;

/** Retain a child while its declared value inputs and own reads agree. */
class EqualChild < T:Equatable > implements View {
  final key:String;
  final input:T;
  final make:T -> BuildContext -> View;

  public function new(key:String, input:T, make:T -> BuildContext -> View) {
    if (key == null || key.length == 0 || make == null) throw "An equal child needs a key and builder";
    this.key = key;
    this.input = input;
    this.make = make;
  }

  public function build(context:BuildContext):RenderNode {
    var state:State<EqualChildCache<T>> = context.resourceState(
      context.id("equal-child:" + key),
      () -> new EqualChildCache<T>(),
      value -> value.dispose()
    );
    var cache = state.value;
    var old = cache.entry;
    if (old != null && !context.bypassRetention
      && old.input == input && old.styleRevision == context.styleRevision && old.width == context.viewportWidth
      && old.height == context.viewportHeight && old.reads.current() && old.interactions.matches(context)) {
      context.retainStateIds(old.refreshStateIds());
      context.retainDependencies(old.reads);
      old.root = context.currentRoot(old.root);
      context.claimRetainedTree(old.root);
      old.root.detach();
      return old.root;
    }
    if (old != null) old.root.detach();
    var stateMark = context.stateUsageMarker();
    var readMark = context.dependencyMarker();
    var view = make(input, context);
    if (view == null) throw "An equal child builder returned no view";
    var root = view.build(context);
    var used = context.stateIdsUsedSince(stateMark);
    var interactions = new InteractionStateSnapshot(context.currentRoot(root), context);
    var reads = context.dependenciesSince(readMark, old == null ? null : old.reads);
    var previousIds = old == null ? null : old.stateIds;
    if (old != null) old.interactions.dispose();
    cache.entry = new EqualChildEntry(
      input,
      context.styleRevision,
      context.viewportWidth,
      context.viewportHeight,
      root,
      used,
      interactions,
      reads,
      previousIds
    );
    return root;
  }
}

private class EqualChildCache < T:Equatable > {
  public var entry:Null<EqualChildEntry<T>>;
  public function new() {
  }
  public function dispose():Void {
    if (entry != null) entry.dispose();
    entry = null;
  }
}

private class EqualChildEntry < T:Equatable > {
  public final input:T;
  public final styleRevision:Int;
  public final width:Float;
  public final height:Float;
  public var root:RenderNode;
  final used:Array<ResourceId>;
  public var stateIds:Array<ResourceId>;
  public final interactions:InteractionStateSnapshot;
  public final reads:Dependencies;

  public function new(
    input:T,
    styleRevision:Int,
    width:Float,
    height:Float,
    root:RenderNode,
    used:Null<Array<ResourceId>>,
    interactions:InteractionStateSnapshot,
    reads:Dependencies,
    previous:Null<Array<ResourceId>>
  ) {
    this.input = input;
    this.styleRevision = styleRevision;
    this.width = width;
    this.height = height;
    this.root = root;
    this.used = used == null ? [] : used.copy();
    this.interactions = interactions;
    this.reads = reads;
    stateIds = interactions.appendStateIds(this.used, previous);
  }
  public function refreshStateIds():Array<ResourceId> {
    stateIds = interactions.appendStateIds(used, stateIds);
    return stateIds;
  }
  public function dispose():Void {
    root.detach();
    interactions.dispose();
    reads.dispose();
  }
}
