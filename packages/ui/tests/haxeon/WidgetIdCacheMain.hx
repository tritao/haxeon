import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;
import haxeon.ui.core.WidgetIdCache;

/** Consecutive virtualized windows reuse storage while dropping the previous rows' identities. */
class WidgetIdCacheCensus {
  static var cache:WidgetIdCache;
  static var paths:Array<String>;
  static var ids:Array<WidgetId>;
  static var even:Map<Int, RenderNode>;
  static var odd:Map<Int, RenderNode>;
  static var states:StateStore;
  static var slots:Int;

  public static function prepare():Void {
    cache = new WidgetIdCache();
    paths = [];
    ids = [];
    even = new Map();
    odd = new Map();
    states = new StateStore();
    for (i in 0...256) {
      var path = "slot:" + i;
      var id = new WidgetId(i + 1), node = new RenderNode(id);
      paths.push(path);
      ids.push(id);
      if ((i & 1) == 0) even.set(id.value, node);
      else odd.set(id.value, node);
      cache.set(path, id);
    }
    slots = cache.storageSlots;
    cache.prune(even, states);
  }

  public static function perform(frames:Int):Int {
    for (frame in 0...frames) {
      for (i in 0...paths.length) cache.set(paths[i], ids[i]);
      var parity = frame & 1;
      cache.prune(parity == 0 ? even : odd, states);
      if (cache.count != 128 || cache.storageSlots != slots) return -1;
      for (i in 0...paths.length) {
        var retained = cache.get(paths[i]);
        if ((i & 1) == parity) {
          if (retained != ids[i]) return -2;
        } else if (retained != null) return -3;
      }
    }
    return frames;
  }
}

function main():Int {
  WidgetIdCacheCensus.prepare();
  if (WidgetIdCacheCensus.perform(8) != 8) return 1;
  #if !wasm
  var before = hl.Gc.totalAllocated();
  #end
  var frames = WidgetIdCacheCensus.perform(1024);
  #if !wasm
  if (hl.Gc.totalAllocated() != before) return 2;
  #end
  return frames == 1024 ? 42 : 3;
}
