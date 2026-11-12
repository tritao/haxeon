import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.component.BoundText;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;

/** A failed binding must not suppress the next host frame request. */
@:access(haxeon.ui.LayoutSession)
class BoundTextFailureMain {
  static function main():Int {
    var ui = new UiContext(new LayoutSession(cast 0));
    var frame = new LayoutFrame(300, 80), source = new Signal<Int>(1), scheduled = 0;
    ui.onAnimationFrameRequested = () -> scheduled++;
    var view:View = new BoundText("value", () -> {
      var value = source.value;
      if (value == 2) throw "expected binding failure";
      return Std.string(value);
    });
    ui.buildContext.beginFrame();
    var node = ui.buildContext.trackReads(() -> view.build(ui.buildContext));
    ui.buildContext.captureRootDependencies();
    ui.stateStore.endFrame();
    source.value = 2;
    if (scheduled != 1) return 1;
    var failed = false;
    try ui.submitCached(() -> view, frame, "cache") catch (_:Dynamic) failed = true;
    if (!failed) return 2;
    source.value = 3;
    if (scheduled != 2) return 3;
    ReactiveRuntime.flushEffects();
    if (node.layout.text != "3" || node.semantics == null || node.semantics.label != "3") return 4;
    return rebindFailure() ? 42 : 5;
  }

  static function rebindFailure():Bool {
    var store = new StateStore(), context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(1);
    context.beginFrame();
    var first = new BoundText("replace", () -> Std.string(source.value));
    var node = context.trackReads(() -> first.build(context));
    store.endFrame();
    context.beginFrame();
    var rejectedSource = new Signal<Int>(0);
    var broken = new BoundText("replace", () -> {
      var value = rejectedSource.value;
      throw "expected rebind failure";
    });
    var failed = false;
    try context.trackReads(() -> broken.build(context)) catch (_:Dynamic) failed = true;
    store.endFrame();
    var connected = source.hasFieldReaders(0) && !rejectedSource.hasFieldReaders(0);
    source.value = 2;
    var recovered = true;
    try ReactiveRuntime.flushEffects() catch (_:Dynamic) recovered = false;
    var valid = failed && connected && recovered && node.layout.text == "2";
    context.dispose();
    return valid;
  }
}
