import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleDiff;
function main():Int {
  var local = new LayoutStyle();
  local.padding = new Insets(1, 2, 3, 4);
  local.background = Color.rgba(0.1, 0.2, 0.3, 1);
  local.transform = Transform2D.translation(5, 6);
  var resolver = new StyleResolver();
  var computed = resolver.resolve(new StyleTarget("value"), null, null, null, local);
  var fork = computed.fork(); resolver.clearCache();
  local.padding = new Insets(8, 8, 8, 8); local.background = Color.rgba(0.8, 0.8, 0.8, 1); local.transform = Transform2D.translation(9, 9);
  var copy = computed.copy(); var a = computed.toLayoutStyle(); var b = fork.toLayoutStyle();
  if (a.padding.left != 1 || a.background.red != 0.1 || a.transform.tx != 5 || b.padding.top != 2 || b.background.green != 0.2 || b.transform.ty != 6) return 1;
  if (StyleDiff.compare(computed, copy).changed || computed.get(StyleProperty.Padding).right != 3) return 2;
  var originalBox:Dynamic = null, copyBox:Dynamic = null, forkBox:Dynamic = null, reflected:Dynamic = null;
  for (entry in computed.entries()) if (entry.name == "padding") {
    originalBox = entry.value;
    reflected = Reflect.field(entry, "value");
  }
  for (entry in copy.entries()) if (entry.name == "padding") copyBox = entry.value;
  for (entry in fork.entries()) if (entry.name == "padding") forkBox = entry.value;
  if (originalBox == null || originalBox != copyBox || originalBox != forkBox || originalBox != reflected) return 4;
  var zero = 0.0, minusZero = zero * -1.0;
  var positive = new LayoutStyle(), negative = new LayoutStyle();
  positive.padding = new Insets(0.0, 1.0, 0.0, 0.0); negative.padding = new Insets(minusZero, 1.0, 0.0, 0.0);
  positive.background = Color.rgba(0.0, 0.2, 0.3, 1.0); negative.background = Color.rgba(minusZero, 0.2, 0.3, 1.0);
  positive.transform = Transform2D.translation(0.0, 5.0); negative.transform = Transform2D.translation(minusZero, 5.0);
  var signs = new StyleResolver();
  signs.resolve(new StyleTarget("sign", "positive"), null, null, null, positive);
  var signed = signs.resolve(new StyleTarget("sign", "negative"), null, null, null, negative).toLayoutStyle();
  if (1.0 / signed.padding.left != Math.NEGATIVE_INFINITY || 1.0 / signed.background.red != Math.NEGATIVE_INFINITY || 1.0 / signed.transform.tx != Math.NEGATIVE_INFINITY) return 3;
  return 42;
}
