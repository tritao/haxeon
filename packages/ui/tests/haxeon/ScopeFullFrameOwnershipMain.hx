import haxeon.reactive.Signal;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RetainedVariants;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.Button;

/** A cache's initial usage list must not keep children removed by their live native parent. */
class ScopeFullFrameOwnershipMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(0);
    var view = new RetainedVariants(
      "cache",
      "A",
      _ -> new TrackedScope("parent", () -> new Button(Std.string(source.value), null, null, "child"))
    );
    context.beginFrame();
    var root = view.build(context), original = context.renderScopeAt(root);
    store.endFrame();
    if (original == null) throw "Missing original child owner";
    source.value = 1;
    context.beginFrame();
    context.flushRenderScopes(root);
    var returned = view.build(context);
    store.endFrame();
    if (returned == root || !returned.id.equals(root.id)) throw "Native replacement lost its root identity";
    if (!original.disposed) throw "Cache usage retained an obsolete native child owner";
    context.dispose();
    return 42;
  }
}
