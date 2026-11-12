import Equatable;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.component.BoundText;
import haxeon.ui.component.EqualChild;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;

struct LifetimeProps implements Equatable {
  public var value:Int;
  public function new(value:Int) this.value = value;
}

/** Compiles against the old control too: cached mounted text must keep its effect alive. */
class BindingLifetimeMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var value = new Signal<Int>(0);
    var view = new TrackedScope("lifetime", () ->
      new EqualChild<LifetimeProps>("stable", new LifetimeProps(1),
        (_, _) -> new BoundText("text", () -> Std.string(value.value))));
    context.beginFrame();
    context.trackReads(() -> view.build(context));
    store.endFrame();
    context.beginFrame();
    var marker = context.stateUsageMarker();
    var root = context.trackReads(() -> view.build(context));
    var ids = context.stateIdsUsedSince(marker);
    store.endFrame();
    // The old control uses an updater record; native scopes use state-store resource ownership.
    // Exercise each implementation's retained lifetime without rebuilding the mounted body.
    context.beginFrame();
    context.retainStateIds(ids);
    var legacyOwner = context.updatingBuild(root);
    if (legacyOwner != null) context.retainUpdatingState(legacyOwner);
    store.endFrame();
    value.value = 1;
    ReactiveRuntime.flushEffects();
    var textMatches = false;
    root.walk(node -> { if (node.layout.text == "1") textMatches = true; });
    var valid = value.hasFieldReaders(0) && textMatches;
    context.dispose();
    return valid ? 42 : 5;
  }
}
