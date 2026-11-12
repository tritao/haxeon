import haxeon.reactive.Signal;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.WidgetId;

/** Native structural ownership does not reconcile or redirect removed nodes. */
class RenderScopeMain {
  static function node(id:Int):RenderNode return new RenderNode(new WidgetId(id));
  static function main():Int {
    var primary = new Signal<Bool>(true), first = new Signal<Int>(1), second = new Signal<Int>(2);
    var root = node(1), decoration = node(2), runs = 0, scheduled = 0, edits = 0;
    var scope = new RenderScope(root, () -> {
      var value = primary.value ? first.value : second.value;
      runs++;
      return node(value + 10);
    }, () -> scheduled++, changed -> {
      if (changed != root) throw "Unexpected scope root";
      edits++;
    });
    scope.refresh();
    root.add(decoration);
    var old = root.children[0];
    scope.refresh();
    if (runs != 1 || edits != 0 || scheduled != 0) return 1;
    first.value = 3;
    if (scheduled != 1) return 2;
    scope.refresh();
    if (runs != 2 || edits != 1 || scheduled != 1 || root.children.length != 2 || root.children[1] != decoration
        || old.parent != null || old.replacedBy != null || root.children[0].id.value != 13) return 3;
    primary.value = false;
    scope.refresh();
    if (first.hasFieldReaders(0) || !second.hasFieldReaders(0) || runs != 3) return 4;
    var before = scheduled;
    first.value = 4;
    scope.refresh();
    if (scheduled != before || runs != 3) return 5;
    scope.dispose();
    scope.dispose();
    if (primary.hasFieldReaders(0) || second.hasFieldReaders(0)) return 6;
    second.value = 5;
    scope.refresh();
    if (scheduled != before || runs != 3) return 7;
    var recoverySource = new Signal<Int>(0), recoveryRoot = node(40), requests = 0;
    var recovering = new RenderScope(recoveryRoot, () -> {
      var value = recoverySource.value;
      if (value == 1) {
        // A retained child can be detached while constructing the next body, before a later child fails.
        recoveryRoot.children[0].detach();
        throw "Expected scope failure";
      }
      return node(41 + value);
    }, () -> requests++, _ -> {});
    recovering.refresh();
    var installed = recoveryRoot.children[0];
    recoverySource.value = 1;
    var failed = false;
    try recovering.refresh() catch (_:Dynamic) failed = true;
    if (!failed || recoveryRoot.children.length != 1 || recoveryRoot.children[0] != installed || installed.parent != recoveryRoot) return 8;
    var failedRequests = requests;
    recoverySource.value = 2;
    if (requests <= failedRequests) return 9;
    recovering.refresh();
    if (recoveryRoot.children[0].id.value != 43 || installed.parent != null) return 10;
    recovering.dispose();
    return recoverySource.hasFieldReaders(0) ? 11 : 42;
  }
}
