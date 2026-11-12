import haxeon.reactive.Signal;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.theme.Theme;

class ScopeLeaf implements View {
  public function new() {}
  public function build(context:BuildContext):RenderNode
    return context.createNode(context.rootId("leaf"), LayoutVisualKind.Box);
}

class ScopeResourceLeaf implements View {
  final key:String;
  public static var released = 0;
  public function new(key:String) this.key = key;
  public function build(context:BuildContext):RenderNode {
    context.resourceState(context.id("resource-" + key), () -> key, _ -> released++);
    return context.createNode(context.rootId("resource-leaf"), LayoutVisualKind.Box);
  }
}

class TrackedScopeMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var read = new Signal<Int>(1), unrelated = new Signal<Int>(0);
    var primary = new Signal<Bool>(true), alternate = new Signal<Int>(10);
    var runs = 0;
    context.beginFrame();
    var scope = new TrackedScope("value", () -> {
      var value = primary.value ? read.value : alternate.value;
      runs++;
      return new ScopeLeaf();
    });
    var root = context.trackReads(() -> scope.build(context));
    store.endFrame();
    if (runs != 1 || !read.hasFieldReaders(0)) return 1;
    var decoration = context.createNode(context.rootId("decoration"), LayoutVisualKind.Box);
    root.add(decoration);
    unrelated.value = 1;
    if (context.hasPendingRenderScopes() || runs != 1) return 2;
    read.value = 2;
    if (!context.hasPendingRenderScopes()) return 3;
    var previousChild = root;
    context.flushRenderScopes(root);
    root = context.currentRoot(root);
    if (context.patchedPriors().get(previousChild.id.value) != previousChild) return 13;
    if (runs != 2 || context.hasPendingRenderScopes() || root.children.length != 1 || decoration.parent != root) return 4;
    primary.value = false;
    context.flushRenderScopes(root);
    if (runs != 3 || read.hasFieldReaders(0) || !alternate.hasFieldReaders(0)) return 6;
    read.value = 3;
    if (context.hasPendingRenderScopes() || runs != 3) return 7;
    alternate.value = 11;
    context.flushRenderScopes(root);
    root = context.currentRoot(root);
    if (runs != 4 || decoration.parent != root || root.children.length != 1) return 8;
    var mounted:Map<Int, RenderNode> = new Map();
    context.beginFrame();
    store.endFrame();
    context.pruneRenderScopes(mounted);
    if (read.hasFieldReaders(0) || primary.hasFieldReaders(0) || alternate.hasFieldReaders(0)) return 5;
    var visible = new Signal<Bool>(true), childSource = new Signal<Int>(0), childRuns = 0;
    context.beginFrame();
    var nested = new TrackedScope("parent", () -> {
      if (!visible.value) return new ScopeLeaf();
      return new TrackedScope("child", () -> {
        var value = childSource.value;
        childRuns++;
        return new ScopeLeaf();
      });
    });
    var nestedRoot = context.trackReads(() -> nested.build(context));
    store.endFrame();
    if (childRuns != 1 || !childSource.hasFieldReaders(0)) return 9;
    childSource.value = 1;
    visible.value = false;
    context.flushRenderScopes(nestedRoot);
    if (childRuns != 1 || childSource.hasFieldReaders(0) || context.hasPendingRenderScopes()) return 10;
    var resourceChoice = new Signal<Bool>(true);
    context.beginFrame();
    var resources = new TrackedScope("resources", () -> new ScopeResourceLeaf(resourceChoice.value ? "a" : "b"));
    var resourceRoot = context.trackReads(() -> resources.build(context));
    store.endFrame();
    resourceChoice.value = false;
    context.flushRenderScopes(resourceRoot);
    context.beginFrame();
    resourceRoot = context.currentRoot(resourceRoot);
    var resourceNodes:Map<Int, RenderNode> = new Map();
    resourceRoot.walk(node -> resourceNodes.set(node.id.value, node));
    context.retainRenderScopeState(resourceNodes);
    store.endFrame();
    if (ScopeResourceLeaf.released != 1) return 11;
    context.beginFrame();
    store.endFrame();
    if (ScopeResourceLeaf.released != 2) return 12;
    var replacementSource = new Signal<Int>(0), replacementRuns = 0;
    var rejectReplacement = false;
    var replacement = new TrackedScope("replacement", () -> {
      var value = replacementSource.value;
      if (rejectReplacement) throw "expected replacement failure";
      replacementRuns++;
      return new ScopeLeaf();
    });
    context.beginFrame();
    var replacementRoot = context.trackReads(() -> replacement.build(context));
    store.endFrame();
    context.beginFrame();
    rejectReplacement = true;
    var failedReplacement = false;
    try context.trackReads(() -> replacement.build(context)) catch (_:Dynamic) failedReplacement = true;
    store.endFrame();
    rejectReplacement = false;
    if (!failedReplacement || !replacementSource.hasFieldReaders(0)) return 21;
    replacementSource.value = 1;
    context.flushRenderScopes(replacementRoot);
    if (replacementRuns != 2) return 22;
    context.beginFrame();
    replacementRoot = context.trackReads(() -> replacement.build(context));
    store.endFrame();
    replacementSource.value = 2;
    context.flushRenderScopes(replacementRoot);
    if (replacementRuns != 4) return 14;
    // A dock cache retains the enclosing build's state IDs while its panel is hidden.
    // The scope's current resources must remain reachable through that retained owner.
    context.beginFrame();
    var cachedMark = context.stateUsageMarker();
    var cachedSource = new Signal<Int>(0), cachedRuns = 0;
    var cachedResource = new TrackedScope("cached-resource", () -> {
      var value = cachedSource.value;
      cachedRuns++;
      return new ScopeResourceLeaf("cached");
    });
    var cachedRoot = context.trackReads(() -> cachedResource.build(context));
    var cachedIds = context.stateIdsUsedSince(cachedMark);
    store.endFrame();
    var releasedBeforeHide = ScopeResourceLeaf.released;
    context.beginFrame();
    context.retainStateIds(cachedIds, true);
    store.endFrame();
    context.pruneRenderScopes(new Map());
    if (ScopeResourceLeaf.released != releasedBeforeHide) return 15;
    cachedSource.value = 1;
    context.flushRenderScopes(null);
    if (cachedRuns != 1 || context.hasPendingRenderScopes()) return 16;
    context.beginFrame();
    context.retainStateIds(cachedIds, true);
    context.claimRetainedTree(cachedRoot);
    context.flushRenderScopes(cachedRoot);
    store.endFrame();
    if (cachedRuns != 2 || !cachedSource.hasFieldReaders(0)) return 17;
    context.beginFrame();
    store.endFrame();
    context.pruneRenderScopes(new Map());
    if (cachedSource.hasFieldReaders(0) || ScopeResourceLeaf.released != releasedBeforeHide + 1) return 18;
    context.dispose();
    return 42;
  }
}
