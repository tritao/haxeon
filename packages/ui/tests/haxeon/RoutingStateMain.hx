import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.InteractionStateStore;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.style.StyleState;

/** Routed input is shared by ID; selected/checked/disabled flags belong to each authored body. */
@:access(haxeon.ui.core.EventDispatcher) @:access(haxeon.ui.core.RenderNode) class RoutingStateMain {
  static function main():Int {
    var values = new InteractionStateStore();
    var dispatcher = new EventDispatcher(new FocusManager(), values);
    var authored = StyleState.Selected | StyleState.Checked | StyleState.Disabled;
    var old = new RenderNode(new WidgetId(1));
    old.states = authored;
    dispatcher.setRoot(old);
    dispatcher.setState(old, StyleState.Hovered, true);
    if (values.get(old.id) != StyleState.Hovered) throw "Routing copied authored flags into the shared input store";
    if (old.states != (authored | StyleState.Hovered)) throw "Routing lost authored flags on the node";
    dispatcher.setState(old, StyleState.Pressed, true);
    var current = new RenderNode(new WidgetId(1));
    current.states = StyleState.Checked;
    dispatcher.setRoot(current);
    dispatcher.setState(old, StyleState.Focused, true);
    var input = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;
    if (values.get(current.id) != input || current.states != (StyleState.Checked | input) || old.states
      != (authored | input)) throw "Replacement routing did not preserve canonical input and per-body flags";
    dispatcher.setState(old, StyleState.Hovered, false);
    input = input.remove(StyleState.Hovered);
    if (values.get(current.id) != input || current.states != (StyleState.Checked | input)
      || old.states != (authored | input)) throw "Replacement hover exit lost canonical input";
    values.set(current.id, StyleState.empty());
    current.routeStates(StyleState.Checked | StyleState.Hovered);
    dispatcher.setState(current, StyleState.Hovered, true);
    if (values.get(current.id) != StyleState.Hovered) throw "A matching node flag suppressed the input store update";
    return 42;
  }
}
