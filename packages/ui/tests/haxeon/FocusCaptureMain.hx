import haxeon.ui.core.UiEventPhase;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.WidgetId;

/** Non-bubbling focus events capture through stable component ancestors and keep their original path. */
class FocusCaptureMain {
  static function main():Int {
    var root = new RenderNode(new WidgetId(1)), wrapper = new RenderNode(new WidgetId(2));
    var target = new RenderNode(new WidgetId(3)), seen:Array<String> = [], bubbles = 0;
    var detach = false, stop = false;
    root.add(wrapper);
    wrapper.add(target);
    for (kind in [UiEventKind.Focus, UiEventKind.Blur]) {
      root.on(kind, function(event) {
        if (!event.target.equals(target.id) || event.phase != UiEventPhase.Capture
          || !event.currentTarget.equals(root.id)) throw "Invalid captured focus event";
        seen.push("root");
        if (detach) wrapper.detach();
      }, UiEventPhase.Capture);
      wrapper.on(kind, function(event) {
        seen.push("wrapper");
        if (stop) event.stopPropagation();
      }, UiEventPhase.Capture);
      target.on(kind, function(event) {
        if (event.phase != UiEventPhase.Capture) throw "Target capture listener ran in the wrong phase";
        seen.push("target-capture");
      }, UiEventPhase.Capture);
      target.on(kind, function(event) {
        if (event.phase != UiEventPhase.Target) throw "Target listener ran outside target delivery";
        seen.push("target");
      }
      );
      root.on(kind, function(_) bubbles++);
      wrapper.on(kind, function(_) bubbles++);
    }
    var events = new EventDispatcher(new FocusManager());
    events.setRoot(root);
    events.focusEvent(target.id, UiEventKind.Focus);
    if (seen.join(",") != "root,wrapper,target-capture,target" || bubbles != 0) return 1;
    seen.resize(0);
    events.focusEvent(target.id, UiEventKind.Blur);
    if (seen.join(",") != "root,wrapper,target-capture,target" || bubbles != 0) return 4;
    seen.resize(0);
    stop = true;
    events.focusEvent(target.id, UiEventKind.Focus);
    if (seen.join(",") != "root,wrapper" || bubbles != 0) return 2;
    seen.resize(0);
    stop = false;
    detach = true;
    events.focusEvent(target.id, UiEventKind.Focus);
    if (seen.join(",") != "root,wrapper,target-capture,target" || wrapper.parent != null || bubbles != 0) return 3;
    return 42;
  }
}
