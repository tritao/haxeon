import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;

class StateStoreLifecycleMain {
  static function main():Int {
    var store = new StateStore();
    var a = new WidgetId(1), b = new WidgetId(2), c = new WidgetId(3), added = new WidgetId(4);
    var countA = 0, countB = 0, countC = 0, countAdded = 0;
    store.initialize(a, 0); store.initialize(b, 0); store.initialize(c, 0);
    store.onUnmount(a, () -> countA++); store.onUnmount(b, () -> countB++); store.onUnmount(c, () -> countC++);
    store.beginFrame(); store.touch(b); store.endFrame();
    if (countA != 1 || countB != 0 || countC != 1 || store.contains(a) || !store.contains(b)) return 1;
    store.initialize(a, 0);
    store.onUnmount(a, () -> {
      countA++;
      store.initialize(added, 0);
      store.onUnmount(added, () -> countAdded++);
    });
    store.beginFrame(); store.touch(a); store.endFrame();
    if (countB != 1 || countA != 1) return 2;
    store.beginFrame(); store.endFrame();
    if (countA != 2 || !store.contains(added) || countAdded != 0) return 3;
    store.beginFrame(); store.endFrame();
    if (countAdded != 1 || store.contains(added)) return 4;
    store.initialize(a, 0); store.initialize(b, 0);
    store.onUnmount(a, () -> { countA++; throw "expected"; });
    store.onUnmount(b, () -> countB++);
    var failed = false;
    store.beginFrame();
    try store.endFrame() catch (_:Dynamic) failed = true;
    if (!failed || store.contains(a) || store.contains(b) || countA != 3 || countB != 2) return 5;
    store.initialize(a, 0); store.initialize(b, 0);
    var recreated = 0;
    store.onUnmount(a, () -> {});
    store.onUnmount(b, () -> {
      store.initialize(a, 0);
      store.onUnmount(a, () -> recreated++);
    });
    store.beginFrame(); store.endFrame();
    if (!store.contains(a)) return 6;
    store.beginFrame(); store.endFrame();
    if (recreated != 1 || store.contains(a)) return 7;
    store.dispose();
    return 42;
  }
}
