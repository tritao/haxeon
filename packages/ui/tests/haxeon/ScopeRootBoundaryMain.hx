import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.ScopeRootBoundary;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.WidgetId;

/** Root replacement transfers caller contributions without retaining the previous body. */
class ScopeRootBoundaryMain {
  static function main():Int {
    var first = new RenderNode(new WidgetId(1));
    first.layout.style.width = LayoutAxis.fixed(10);
    var firstBody = new RenderNode(new WidgetId(2));
    first.add(firstBody);
    var own = 0, caller = 0;
    first.on(UiEventKind.Focus, _ -> own += 100);
    var boundary = new ScopeRootBoundary(first);
    first.layout.style.width = LayoutAxis.fixed(100);
    var overlay = new RenderNode(new WidgetId(3));
    first.add(overlay);
    first.on(UiEventKind.Focus, _ -> caller++);
    var next = new RenderNode(first.id);
    next.layout.style.width = LayoutAxis.fixed(100);
    next.layout.style.height = LayoutAxis.fixed(25);
    var nextBody = new RenderNode(new WidgetId(4));
    next.add(nextBody);
    next.on(UiEventKind.Focus, _ -> own++);
    boundary.transfer(first, next);
    if (next.children.length != 2 || next.children[0] != nextBody || next.children[1] != overlay ||
        overlay.parent != next || firstBody.parent != first || first.children.length != 1) return 1;
    var events = new EventDispatcher(new FocusManager());
    events.setRoot(next);
    events.focusEvent(next.id, UiEventKind.Focus);
    if (own != 1 || caller != 1) return 2;
    var third = new RenderNode(first.id);
    third.layout.style.width = LayoutAxis.fixed(200);
    third.layout.style.height = LayoutAxis.fixed(50);
    boundary.transfer(next, third);
    if (!haxeon.Equality.equals(third.layout.style.width, LayoutAxis.fixed(100)) ||
        !haxeon.Equality.equals(third.layout.style.height, LayoutAxis.fixed(50)) ||
        third.children.length != 1 || third.children[0] != overlay || nextBody.parent != next) return 3;
    events.setRoot(third);
    events.focusEvent(third.id, UiEventKind.Focus);
    if (own != 1 || caller != 2) return 4;
    boundary.transfer(third, third);
    events.focusEvent(third.id, UiEventKind.Focus);
    if (own != 1 || caller != 3 || third.children.length != 1) return 5;
    return forwarding() ? 42 : 6;
  }

  static function forwarding():Bool {
    var first = new RenderNode(new WidgetId(10));
    first.add(new RenderNode(new WidgetId(11)));
    var own = 0, caller = 0;
    first.on(UiEventKind.Focus, _ -> own += 100);
    var inner = new ScopeRootBoundary(first);
    var outerChild = first.add(new RenderNode(new WidgetId(12)));
    first.on(UiEventKind.Focus, _ -> own += 10);
    var outer = new ScopeRootBoundary(first);
    var overlay = first.add(new RenderNode(new WidgetId(13)));
    first.on(UiEventKind.Focus, _ -> caller++);
    var next = new RenderNode(first.id);
    next.add(new RenderNode(new WidgetId(14)));
    next.add(new RenderNode(new WidgetId(15)));
    next.on(UiEventKind.Focus, _ -> own++);
    next.on(UiEventKind.Focus, _ -> own++);
    outer.rebase(inner, next);
    inner.transfer(first, next);
    if (next.children.length != 4 || !outer.owns(next.children[0]) || !outer.owns(next.children[1]) ||
        !outer.owns(outerChild) || outer.owns(overlay)) return false;
    var last = new RenderNode(first.id);
    last.on(UiEventKind.Focus, _ -> own += 2);
    outer.transfer(next, last);
    if (last.children.length != 1 || last.children[0] != overlay || outerChild.parent != next) return false;
    var events = new EventDispatcher(new FocusManager());
    events.setRoot(last);
    events.focusEvent(last.id, UiEventKind.Focus);
    return own == 2 && caller == 1;
  }
}
