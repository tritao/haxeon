import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;
class StateStoreIdleCensus {
  static function main():Int {
    var store = new StateStore(), id = new WidgetId(1);
    store.initialize(id, 1); store.onUnmount(id, () -> {});
    for (_ in 0...3) { store.beginFrame(); store.touch(id); store.endFrame(); }
    hl.Gc.censusStart(0);
    for (_ in 0...100) { store.beginFrame(); store.touch(id); store.endFrame(); }
    hl.Gc.censusStop(); hl.Gc.censusDump(Sys.args()[0]);
    store.dispose();
    return 42;
  }
}
