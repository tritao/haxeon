import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Transform2D;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.WidgetId;

/** Event construction and listener setup precede the measured dispatch interval. */
@:access(haxeon.ui.core.EventDispatcher)
class FocusDispatchCensus {
  static var dispatcher:EventDispatcher;
  static var target:RenderNode;
  static var focused:UiEvent;
  static var blurred:UiEvent;
  static var deliveries:Int;

  public static function prepare():Void {
    var root = new RenderNode(new WidgetId(1)), wrapper = new RenderNode(new WidgetId(2));
    target = new RenderNode(new WidgetId(3));
    root.add(wrapper); wrapper.add(target);
    for (node in [root, wrapper, target]) {
      var bounds = new Rect(0, 0, 100, 80);
      node.resolved = new ResolvedLayoutItem(node.id.value, 1, 3, 4, 100, 80,
        bounds, bounds, new Transform2D(2, 0, 0, 2, 5, 6), 0);
    }
    for (kind in [UiEventKind.Focus, UiEventKind.Blur]) {
      root.on(kind, function(_) deliveries++, "capture");
      wrapper.on(kind, function(_) deliveries++, "capture");
      target.on(kind, function(_) deliveries++);
    }
    focused = new UiEvent(UiEventKind.Focus, target.id);
    blurred = new UiEvent(UiEventKind.Blur, target.id);
    dispatcher = new EventDispatcher(new FocusManager());
    dispatcher.setRoot(root);
    deliveries = 0;
  }

  public static function perform(count:Int):Int {
    deliveries = 0;
    for (_ in 0...count) {
      dispatcher.dispatchPreparedDirect(target, focused);
      dispatcher.dispatchPreparedDirect(target, blurred);
    }
    return deliveries;
  }
}

function main():Int {
  FocusDispatchCensus.prepare();
  if (FocusDispatchCensus.perform(8) != 48) return 1;
  #if !wasm
  var before = hl.Gc.totalAllocated();
  #end
  var deliveries = FocusDispatchCensus.perform(1024);
  #if !wasm
  if (hl.Gc.totalAllocated() != before) return 2;
  #end
  return deliveries == 6144 ? 42 : 3;
}
