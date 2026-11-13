import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.WidgetId;

function main():Int {
  var event = new UiEvent(UiEventKind.Click, new WidgetId(1));
  event.phase = "capture";
  return 42;
}
