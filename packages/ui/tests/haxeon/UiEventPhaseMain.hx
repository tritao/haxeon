import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiEventPhase;
import haxeon.ui.core.WidgetId;

/** Listener policy never leaks extra phases into routed or direct event delivery. */
@:access(haxeon.ui.core.RenderNode) class UiEventPhaseMain {
  static function main():Int {
    var node = new RenderNode(new WidgetId(1));
    var target = new RenderNode(new WidgetId(2));
    var seen:Array<String> = [];
    var event = new UiEvent(UiEventKind.Click, node.id);
    if (event.phase != UiEventPhase.Target) return 1;
    node.on(UiEventKind.Click, _ -> seen.push("capture"), UiEventPhase.Capture);
    node.on(UiEventKind.Click, _ -> seen.push("target"), UiEventPhase.Target);
    node.on(UiEventKind.Click, _ -> seen.push("bubble"));
    node.onTargetBubble(UiEventKind.Click, _ -> seen.push("target-bubble"));
    event.phase = UiEventPhase.Capture;
    node.invoke(event);
    if (seen.join(",") != "capture") return 2;
    seen.resize(0);
    event.phase = UiEventPhase.Target;
    node.invoke(event);
    if (seen.join(",") != "target,bubble,target-bubble" || event.phase != UiEventPhase.Target) return 3;
    seen.resize(0);
    var descendant = new UiEvent(UiEventKind.Click, target.id);
    descendant.phase = UiEventPhase.Bubble;
    node.invoke(descendant);
    if (seen.join(",") != "bubble") return 4;
    var outside = 0;
    node.onPointerDownOutside(function(delivery) {
      if (delivery.phase != UiEventPhase.Target || !delivery.currentTarget.equals(node.id)
        || !delivery.target.equals(target.id)) throw "Invalid outside notification delivery";
      outside++;
    }
    );
    node.invokePointerDownOutside(new UiEvent(UiEventKind.PointerDown, target.id));
    if (outside != 1 || seen.join(",") != "bubble") return 5;
    return 42;
  }
}
