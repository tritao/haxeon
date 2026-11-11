import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.component.BoundText;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;

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
    return node.layout.text == "3" && node.semantics != null && node.semantics.label == "3" ? 42 : 4;
  }
}
