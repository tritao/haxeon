import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.WidgetId;

function main():Int {
  var node = new RenderNode(new WidgetId(1));
  node.on(UiEventKind.Click, _ -> {}, "capture");
  return 42;
}
