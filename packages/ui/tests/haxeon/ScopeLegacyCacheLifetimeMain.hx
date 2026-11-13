import haxeon.reactive.Signal;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.core.RetainedVariants;

class ScopeLegacyCacheLifetimeMain implements View {
  final choice = new Signal<Bool>(true);
  public function new() {
  }

  public function build(context:BuildContext):RenderNode {
    var id = context.id("legacy-cache-parent");
    return context.selfUpdating(id, () -> {var root = new RenderNode(id);
    var key = choice.value ? "A" : "B";
    root.add(new RetainedVariants("alternatives",
      key, _ -> new TrackedScope("native", () -> new CachedResourceLeaf())).build(context));
    return root;
    });
  }

  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var view = new ScopeLegacyCacheLifetimeMain();
    context.beginFrame();
    var root = context.trackReads(() -> view.build(context));
    var first = root.children[0], owner = context.renderScopeAt(first);
    store.endFrame();
    if (owner == null) throw "Missing cached native owner";
    view.choice.value = false;
    context.beginFrame();
    context.flushRenderScopes(root);
    context.applyPatches();
    context.flushRenderScopes(root);
    var mounted:Map<Int, RenderNode> = new Map();
    root.walk(node -> mounted.set(node.id.value, node));
    context.retainRenderScopeState(mounted);
    store.endFrame();
    context.pruneRenderScopes(mounted);
    if (owner.disposed) throw "Hidden legacy variant disposed native owner";
    if (CachedResourceLeaf.released != 0) throw "Hidden legacy variant released live widget state";
    view.choice.value = true;
    context.beginFrame();
    context.applyPatches();
    context.flushRenderScopes(root);
    if (root.children.length != 1
      || !first.id.equals(root.children[0].id)) throw "Legacy variant did not restore native body identity";
    if (CachedResourceLeaf.created != 2) throw "Returning legacy variant recreated retained widget state";
    context.dispose();
    return 42;
  }
}

private class CachedResourceLeaf implements View {
  public static var released = 0;
  public static var created = 0;
  public function new() {
  }
  public function build(context:BuildContext):RenderNode {
    context.resourceState(context.id("resource"), () -> {created++;
    return 1;
    }, _ -> released++);
    return context.createNode(context.rootId("body"));
  }
}
