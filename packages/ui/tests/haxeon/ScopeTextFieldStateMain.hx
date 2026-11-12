import haxeon.ui.component.TrackedScope;
import haxeon.ui.FontCollection;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.text.TextField;

class ScopeTextFieldStateMain {
  static function main():Int {
    var fonts = FontCollection.create();
    var path = Sys.getEnv("NKUI_TEST_FONT_PATH");
    if (path == null) throw "NKUI_TEST_FONT_PATH is required";
    fonts.add(path);
    var context = new BuildContext(new StateStore(), fonts, null, null, Theme.light());
    var view = new TrackedScope("editor", () -> new TextField("field", "Text"));
    for (_ in 0...3) {
      context.beginFrame();
      var root = view.build(context);
      if (context.renderScopeAt(root) == null) throw "Editor root lost its scope owner";
      context.stateStore.endFrame();
    }
    context.dispose(); context.stateStore.dispose();fonts.dispose();
    return 42;
  }
}
