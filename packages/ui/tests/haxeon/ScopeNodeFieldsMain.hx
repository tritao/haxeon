import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.core.ScopeRootBoundary;
import haxeon.ui.core.CursorShape;
import haxeon.ui.core.HitTestBehavior;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

class ScopeNodeFieldsMain {
  static function main():Int {
    var first = new RenderNode(new WidgetId(1));
    var boundary = new ScopeRootBoundary(first);
    first.cursor = CursorShape.Hand;
    first.tabIndex = 7;
    first.commandScope = "caller";
    first.windowDecoration = WindowDecorationRegionKind.Drag;
    first.windowDecorationCursor = CursorShape.Move;
    first.hitTestBehavior = HitTestBehavior.ChildrenOnly;
    first.focusTrap = true;
    first.hitTestSelf = false;
    var next = new RenderNode(first.id);
    boundary.transfer(first, next);
    check(next);
    // Caller ownership persists when a subsequent body's default happens to coincide.
    var third = new RenderNode(first.id);
    third.tabIndex = 7;
    boundary.transfer(next, third);
    check(third);
    var last = new RenderNode(first.id);
    boundary.transfer(third, last);
    check(last);
    var plain = new RenderNode(new WidgetId(2));
    plain.cursor = CursorShape.Text;
    var authored = new ScopeRootBoundary(plain);
    var changed = new RenderNode(plain.id);
    changed.cursor = CursorShape.Crosshair;
    changed.tabIndex = 12;
    authored.transfer(plain, changed);
    if (changed.cursor != CursorShape.Crosshair
      || changed.tabIndex != 12) throw "Body-owned fields failed to advance without a caller override";
    return 42;
  }
  static function check(node:RenderNode):Void {
    if (node.cursor != CursorShape.Hand
      || node.tabIndex != 7 || node.commandScope != "caller" || node.windowDecoration != WindowDecorationRegionKind.Drag
      || node.windowDecorationCursor != CursorShape.Move || node.hitTestBehavior != HitTestBehavior.ChildrenOnly
      || !node.focusTrap || node.hitTestSelf) throw "Caller node fields lost on body replacement";
  }
}
