import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.RenderNode;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.text.Text;
import haxeon.reactive.Signal;

/** Cached component instances may share a widget identity, but never their native ownership record. */
class ScopeInstanceLifetimeMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(1);
    var a = new TrackedScope("shared", () -> new Text("A" + source.value));
    var b = new TrackedScope("shared", () -> new Text("B"));
    context.beginFrame();
    var mark = context.stateUsageMarker();
    var rootA = a.build(context), ownerA = context.renderScopeAt(rootA);
    if (ownerA == null) throw "A has no native owner";
    var idsA = context.stateIdsUsedSince(mark);
    store.endFrame();
    context.beginFrame();
    context.retainStateIds(idsA);
    mark = context.stateUsageMarker();
    var rootB = b.build(context), ownerB = context.renderScopeAt(rootB);
    if (ownerB == null) throw "B has no native owner";
    var idsB = context.stateIdsUsedSince(mark);
    if (!rootA.id.equals(rootB.id)) throw "Alternatives lost their shared widget identity";
    if (ownerA.disposed || ownerA.resourceId
      == ownerB.resourceId) throw "A cached native component's lifetime was overwritten by another instance";
    var mounted:Map<Int, RenderNode> = new Map();
    mounted.set(rootB.id.value, rootB);
    context.pruneRenderScopes(mounted);
    store.endFrame();
    source.value = 2;
    if (context.hasPendingRenderScopes()) throw "An inactive scope scheduled a mounted rebuild";
    context.flushRenderScopes(rootB);
    if (ownerA.disposed || !source.hasFieldReaders(0)) throw "An inactive retained scope lost its subscriptions";
    context.beginFrame();
    context.retainStateIds(idsA);
    context.retainStateIds(idsB);
    context.claimRetainedTree(rootA);
    context.flushRenderScopes(rootA);
    var returned = context.currentRoot(rootA);
    if (returned.layout.text != "A2" || context.currentRoot(rootB).layout.text
      != "B") throw "Returning to a cached instance used another component's body";
    store.endFrame();
    context.dispose();
    store.dispose();
    if (source.hasFieldReaders(0)) throw "Released native instance retained a reader";
    return 42;
  }
}
