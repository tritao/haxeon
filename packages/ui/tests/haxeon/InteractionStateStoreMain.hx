import haxeon.ui.core.InteractionStateStore;
import haxeon.ui.core.WidgetId;
import haxeon.ui.style.StyleState;

class InteractionStateStoreMain {
  static var store:InteractionStateStore;
  static var first:WidgetId;
  static var second:WidgetId;

  public static function prepare():Void {
    store = new InteractionStateStore();
    first = new WidgetId(1);
    second = new WidgetId(2);
  }

  static function transaction():Int {
    var revision = store.revision;
    store.set(first, StyleState.empty());
    if (store.revision != revision) return -1;
    store.set(first, StyleState.Hovered);
    store.set(second, StyleState.Focused);
    store.set(first, StyleState.Hovered | StyleState.Pressed);
    store.set(second, StyleState.empty());
    var changes = store.changes();
    if (changes != store.changes() || changes.length != 1 || changes[0].id != first.value
      || !changes[0].before.isEmpty() || changes[0].after != (StyleState.Hovered | StyleState.Pressed)) return -2;
    store.acknowledge();
    if (store.changes() != changes || changes.length != 0) return -3;
    store.set(first, StyleState.empty());
    store.set(second, StyleState.Focused);
    changes = store.changes();
    var sawFirst = false, sawSecond = false;
    if (changes.length != 2) return -4;
    for (change in changes) {
      if (change.id == first.value) sawFirst = change.before == (StyleState.Hovered | StyleState.Pressed)
        && change.after.isEmpty();
      if (change.id == second.value) sawSecond = change.before.isEmpty() && change.after == StyleState.Focused;
    }
    if (!sawFirst || !sawSecond) return -5;
    store.acknowledge();
    store.set(second, StyleState.empty());
    changes = store.changes();
    if (changes.length != 1 || changes[0].id != second.value
      || changes[0].before != StyleState.Focused || !changes[0].after.isEmpty()) return -6;
    store.acknowledge();
    return 1;
  }

  public static function perform(frames:Int):Int {
    for (_ in 0...frames) {
      var result = transaction();
      if (result != 1) return result;
    }
    return frames;
  }

  static function main():Int {
    prepare();
    if (!store.get(null).isEmpty()) return 1;
    var rejected = false;
    try store.set(null, StyleState.empty()) catch (_:Dynamic) rejected = true;
    if (!rejected || perform(8) != 8) return 2;
    #if !wasm
    var before = hl.Gc.totalAllocated();
    #end
    if (perform(1024) != 1024) return 3;
    #if !wasm
    if (hl.Gc.totalAllocated() != before) return 4;
    #end
    store.dispose();
    if (!store.get(first).isEmpty() || store.changes().length != 0) return 5;
    return 42;
  }
}
