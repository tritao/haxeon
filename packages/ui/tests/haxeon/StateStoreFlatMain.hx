import haxeon.ui.core.StateStore;
import haxeon.ui.core.ResourceId;
import haxeon.ui.core.WidgetId;

/** Usage spans and resource sweep lists retain capacity across captures, compaction and refills. */
class StateStoreFlatMain {
  static var released = 0;
  static function release():Void released++;
  static function main():Int {
    var store = new StateStore(), ids = [for (i in 0...600) new WidgetId(i + 1)];
    store.beginFrame();
    for (index in 0...400) {
      store.initialize(ids[index], index);
      store.onUnmount(ids[index], release);
    }
    store.endFrame();
    store.beginFrame();
    var outer = store.beginUsage();
    store.touch(ids[10]);
    var inner = store.beginUsage();
    store.touch(ids[20]);
    store.touch(ids[20]);
    var child = store.usedIdsSince(inner);
    if (child.length != 1 || child[0] != ResourceId.widget(ids[20])) return 1;
    store.finishUsage(inner);
    store.touch(ids[30]);
    var parent = store.usedIdsSince(outer);
    if (parent.length != 2
      || parent[0] != ResourceId.widget(ids[10]) || parent[1] != ResourceId.widget(ids[30])) return 2;
    store.finishUsage(outer);
    for (index in 0...400) if (index % 2 == 0) store.touch(ids[index]);
    store.endFrame();
    if (released != 200 || store.diagnosticCounts().resources != 200) return 3;
    store.beginFrame();
    for (index in 0...400) if (index % 2 == 0) store.touch(ids[index]);
    for (index in 400...600) {
      store.initialize(ids[index], index);
      store.onUnmount(ids[index], release);
    }
    if (store.usageMarker() != 400) return 4;
    store.endFrame();
    if (released != 200 || store.diagnosticCounts().resources != 400) return 5;
    store.beginFrame();
    store.endFrame();
    if (released != 600 || store.diagnosticCounts().resources != 0) return 6;
    store.dispose();
    return 42;
  }
}
