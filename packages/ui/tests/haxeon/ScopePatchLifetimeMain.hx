import haxeon.ui.FontCollection;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutFrame;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.UiContext;
import haxeon.ui.widgets.controls.Button;
import haxeon.reactive.Signal;

/** Replacing child descriptions through independent native updates must retire their ownership records. */
class ScopePatchLifetimeMain {
  static function main():Int {
    var fonts = FontCollection.create();fonts.add(Sys.getEnv("NKUI_TEST_FONT_PATH"));
    var session = LayoutSession.create(), ui = new UiContext(session, fonts);
    ui.verifyRetentionEvery = 1;
    var value = new Signal<Int>(0);
    var view = new TrackedScope("outer", () -> new Button(Std.string(value.value), null, null, "button"));
    var build = () -> view;
    var frame = new LayoutFrame(200, 80);
    ui.submitCached(build, frame, "stable");
    var baseline = ui.buildContext.stateStore.diagnosticCounts().resources;
    for (i in 1...540) {
      value.value = i;ui.submitCached(build, frame, "stable");
      if (ui.buildContext.stateStore.diagnosticCounts().resources != baseline)
        throw "Native patch updates retained obsolete component owners";
    }
    ui.dispose();session.dispose();fonts.dispose();return 42;
  }
}
