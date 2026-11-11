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
    return new RenderNode(context.id("leaf"), LayoutVisualKind.Box);
}

class TrackedScopeMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var read = new Signal<Int>(1), unrelated = new Signal<Int>(0);
    var runs = 0;
    context.beginFrame();
    var scope = new TrackedScope("value", () -> { var value = read.value; runs++; return new ScopeLeaf(); });
    var root = context.trackReads(() -> scope.build(context));
    store.endFrame();
    if (runs != 1 || !read.hasFieldReaders(0)) return 1;
    unrelated.value = 1;
    if (context.hasPendingPatches || runs != 1) return 2;
    read.value = 2;
    if (!context.hasPendingPatches) return 3;
    context.applyPatches();
    if (runs != 2 || context.hasPendingPatches || root.children.length != 1) return 4;
    var mounted:Map<Int, RenderNode> = new Map();
    context.pruneSelfUpdatingBuilds(mounted);
    if (read.hasFieldReaders(0)) return 5;
    context.dispose();
    return 42;
  }
}
