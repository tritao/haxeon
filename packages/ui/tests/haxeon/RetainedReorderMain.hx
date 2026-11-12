import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;

class RetainedReorderMain {
  static function node(id:Int):RenderNode return new RenderNode(new WidgetId(id), LayoutVisualKind.Box);
  static function main():Int {
    var scope = node(30), body = node(31), decoration = node(32), updated = node(33);
    scope.add(body); scope.add(decoration);
    scope.replaceChild(body, updated);
    if (scope.children.length != 2 || scope.children[0] != updated || scope.children[1] != decoration
        || scope.layout.children[0] != updated.layout || scope.layout.children[1] != decoration.layout
        || body.parent != null || body.replacedBy != null || updated.parent != scope) return 6;
    var cycleRejected = false;
    try scope.replaceChild(updated, scope) catch (_:Dynamic) cycleRejected = true;
    if (!cycleRejected || scope.children[0] != updated || updated.parent != scope) return 7;
    var old = node(1), a = node(2), b = node(3);
    old.add(a); old.add(b);
    var built = old.snapshotBuilt();
    var extra = node(5);
    old.add(extra);
    var fresh = node(1), c = node(4);
    b.detach(); fresh.add(b); fresh.add(c);
    old.reconcile(fresh, built);
    if (old.children.length != 3 || old.children[0] != b || old.children[1] != c || old.children[2] != extra)
      return 1;
    if (old.layout.children.length != 3 || old.layout.children[0] != b.layout || old.layout.children[1] != c.layout
        || old.layout.children[2] != extra.layout || a.parent != null) return 2;
    var next = node(1);
    c.detach(); b.detach(); next.add(c); next.add(b);
    old.reconcile(next, built);
    if (old.children.length != 3 || old.children[0] != c || old.children[1] != b || old.children[2] != extra)
      return 3;
    var ordinary = node(10), x = node(11), y = node(12), caller = node(13);
    ordinary.add(x); ordinary.add(y);
    var ordinaryBuilt = ordinary.snapshotBuilt();
    ordinary.add(caller);
    var replacement = node(10), p = node(14), q = node(15);
    replacement.add(p); replacement.add(q);
    ordinary.reconcile(replacement, ordinaryBuilt);
    if (ordinary.children.length != 3 || ordinary.children[0] != p || ordinary.children[1] != q
        || ordinary.children[2] != caller) return 4;
    var stable = node(20), keep = node(21), replaced = node(22), newChild = node(23);
    stable.add(keep); stable.add(replaced);
    var stableBuilt = stable.snapshotBuilt();
    var stableCaller = node(24);
    stable.add(stableCaller);
    var stableNext = node(20);
    keep.detach(); stableNext.add(keep); stableNext.add(newChild);
    stable.reconcile(stableNext, stableBuilt);
    if (stable.children.length != 3 || stable.children[0] != keep || stable.children[1] != newChild
        || stable.children[2] != stableCaller || stable.layout.children.length != 3
        || stable.layout.children[0] != keep.layout || stable.layout.children[1] != newChild.layout
        || stable.layout.children[2] != stableCaller.layout || replaced.parent != null) return 5;
    return 42;
  }
}
