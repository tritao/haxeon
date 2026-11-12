import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.reactive.Signal;

/** A scope owner and a stateful body root occupy distinct resource identities. */
@:access(haxeon.ui.core.BuildContext) class ScopeRootStateMain {
  static function main():Int {
    var reads = new Signal<Int>(0);
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    var view = new TrackedScope("stateful", () -> {var value = reads.value;
    return new Checkbox("check", "Check", value > 0, _ -> {});
    });
    for (i in 0...3) {
      context.beginFrame();
      reads.value = i;
      var root = view.build(context);
      if (context.renderScopeAt(root) == null) throw "Stateful body lost its native owner";
      context.stateStore.endFrame();
    }
    context.dispose();
    context.stateStore.dispose();
    if (reads.hasFieldReaders(0)) throw "Disposed stateful scope retained a reader";
    installationFailure();
    return 42;
  }
  public static function installationFailure():Void {
    var store = new RejectingScopeStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(0);
    var view = new TrackedScope("rejected", () -> new Checkbox("check", Std.string(source.value)));
    context.beginFrame();
    var failed = false;
    try view.build(context) catch (error:Dynamic) {
      if (Std.string(error) != "Expected installation failure") throw error;
      failed = true;
    }
    if (!failed || source.hasFieldReaders(0)
      || context.renderScopes.length != 0) throw "Failed installation retained a subscribed native owner";
    context.dispose();
    store.dispose();
  }
}

private class RejectingScopeStore extends StateStore {
  override public function installScope(owner:haxeon.ui.core.RenderScope):Void {
    throw "Expected installation failure";
  }
}
