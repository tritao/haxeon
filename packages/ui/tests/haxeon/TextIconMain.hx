import haxeon.ui.Color;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.style.StyleSelector;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleValue;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.text.Text;

/** Native leaves preserve inherited, authored and local typography on every target. */
class TextIconMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    context.beginFrame();
    var inherited = context.currentTextStyle();
    var plain = context.withScope(new Key("plain"), () -> new Text("plain").build(context));
    if (plain.layout.text != "plain" || plain.semantics == null || plain.semantics.label != "plain"
        || plain.layout.textStyle.fontSize != inherited.textStyle.fontSize
        || plain.layout.textStyle.letterSpacing != inherited.textStyle.letterSpacing) return 1;

    var sheet = new StyleSheet("leaf-typography");
    sheet.rule(StyleSelector.widget("text"), [StyleValue.fontSize(31.0),
      StyleValue.letterSpacing(0.0), StyleValue.textColor(Color.fromBytes(0, 0, 0, 0))]);
    context.setStyleSheet(sheet);
    var authored = context.withScope(new Key("authored"), () -> new Text("authored").build(context));
    if (authored.layout.textStyle.fontSize != 31.0 || authored.layout.textStyle.letterSpacing != 0.0
        || authored.layout.textColor.alpha != 0.0) return 2;

    var blue = Color.fromBytes(0, 0, 255);
    var local = context.withScope(new Key("local"), () -> new Text("local", null, blue,
      TextStyleOverride.text(18.0, 2.0, Color.fromBytes(255, 0, 0))).build(context));
    if (local.layout.textStyle.fontSize != 18.0 || local.layout.textStyle.letterSpacing != 2.0
        || local.layout.textColor.blue != 1.0 || local.layout.textColor.red != 0.0) return 3;

    var icon = new Icon("search", IconName.Search, 20.0, blue, "Search").build(context);
    if (icon.layout.visualKind != LayoutVisualKind.Custom || icon.hitTestSelf
        || icon.layout.style.width.value != 20.0 || icon.layout.style.height.value != 20.0
        || icon.semantics == null || icon.semantics.role != AccessibilityRole.Image
        || icon.semantics.label != "Search") return 4;
    var decorative = new Icon("decoration", IconName.Search).build(context);
    if (decorative.semantics != null || decorative.hitTestSelf) return 5;
    store.endFrame();
    context.dispose();
    return 42;
  }
}
