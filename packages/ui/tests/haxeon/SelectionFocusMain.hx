import haxeon.ui.core.BuildContext;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Rect;
import haxeon.ui.Transform2D;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.SelectOption;

class SelectionFocusMain {
  static function resolve(root:RenderNode):Void {
    root.walk(node -> {
      var bounds = new Rect(0, 0, 100, 80);
      node.resolved = new ResolvedLayoutItem(node.id.value, 1, 0, 0, 100, 80, bounds, bounds, new Transform2D(1,0,0,1,0,0), 0);
    });
  }
  static function main():Int {
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    var focus = new FocusManager();
    var events = new EventDispatcher(focus);
    var requested = 0;
    context.setFocusRequester(id -> {
      requested++;
      if (!focus.focus(id)) throw "Selection requested focus on a non-focusable label or icon";
      return true;
    });
    var view = new Select("select", [new SelectOption("a", "A", 1), new SelectOption("b", "B", 2)], 1);
    context.beginFrame();
    var root = view.build(context);
    resolve(root);focus.rebuild(root); events.setRoot(root);
    var trigger = root.children[0];
    if (!focus.focus(trigger.id)) throw "Trigger must be focusable";
    events.key(UiEventKind.KeyDown, UiKey.Down, UiModifier.empty());
    context.beginFrame();root = view.build(context);
    resolve(root);focus.rebuild(root);events.setRoot(root);trigger=root.children[0];
    focus.focus(trigger.id);
    events.key(UiEventKind.KeyDown, UiKey.Escape, UiModifier.empty());
    if (requested != 1 || !trigger.id.equals(focus.focusedId)) throw "Closing Select did not focus its trigger";
    events.key(UiEventKind.KeyDown, UiKey.Down, UiModifier.empty());
    context.beginFrame();root=view.build(context);
    resolve(root);focus.rebuild(root);events.setRoot(root);trigger=root.children[0];
    focus.focus(trigger.id);
    events.key(UiEventKind.KeyDown, UiKey.Down, UiModifier.empty());
    if (requested != 2 || focus.focusedId.equals(trigger.id)) throw "Arrow navigation did not focus an option";
    events.key(UiEventKind.KeyDown, UiKey.Up, UiModifier.empty());
    if (requested != 3) throw "Popup navigation did not request option focus";
    context.dispose();context.stateStore.dispose();
    return 42;
  }
}
