import haxeon.ui.FontCollection;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutFrame;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.UiContext;
import haxeon.ui.widgets.controls.Checkbox;

/** A legacy stateful body can reuse a physical root without keeping obsolete component owners alive. */
class ScopeRootStateUiMain {
  static function main():Int {
    var fonts = FontCollection.create();
    fonts.add(Sys.getEnv("NKUI_TEST_FONT_PATH"));
    var session = LayoutSession.create(), ui = new UiContext(session, fonts);
    var view = new TrackedScope("stateful", () -> new Checkbox("check", "Check", false, _ -> {}));
    var frame = new LayoutFrame(200, 80), baseline = -1;
    for (_ in 0...8) {
      ui.submit(view, frame);
      var resources = ui.buildContext.stateStore.diagnosticCounts().resources;
      if (baseline < 0) baseline = resources;
      if (resources != baseline) throw "Reused physical root kept obsolete native owners alive";
    }
    ui.dispose();
    session.dispose();
    fonts.dispose();
    return 42;
  }
}
