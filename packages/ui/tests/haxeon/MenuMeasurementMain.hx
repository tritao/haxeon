import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.widgets.controls.Button;

/** Menu width measurement uses only padding and typography, never the button's row alignment/gap. */
class MenuMeasurementMain {
  static function main():Int {
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    var target = new StyleTarget("button", "item", "item", ["menu-item", "navigation"], ["button"], StyleState.empty());
    var button = new Button("Item");
    var prior = context.resolveStyle(target, button.style);
    var current = context.resolveStyle(target, null);
    var a = prior.toLayoutStyle(), b = current.toLayoutStyle();
    if (a.padding.left != b.padding.left || a.padding.right != b.padding.right
      || prior.getNumber(StyleProperty.FontSize) != current.getNumber(StyleProperty.FontSize)
      || prior.getNumber(StyleProperty.LetterSpacing) != current
      .getNumber(StyleProperty.LetterSpacing)) throw "Menu's measurement padding or typography differs from its Button";
    context.dispose();
    context.stateStore.dispose();
    return 42;
  }
}
