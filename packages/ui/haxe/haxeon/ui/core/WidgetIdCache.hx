package haxeon.ui.core;

/** Sorted path/ID pairs. Removing recycled rows compacts live pairs without growing a map freelist. */
class WidgetIdCache {
  final paths:Array<Null<String>> = [];
  final ids:Array<Null<WidgetId>> = [];
  public var count(default, null):Int = 0;
  /** High-water storage slots, retained across prune and clear rather than trimmed and regrown. */
  public var storageSlots(get, never):Int;
  inline function get_storageSlots():Int return paths.length;

  public function new() {
  }

  public function get(path:String):Null<WidgetId> {
    var position = find(path);
    return position < 0 ? null : ids[position];
  }

  public function exists(path:String):Bool return find(path) >= 0;

  public function set(path:String, id:WidgetId):Void {
    if (path == null || id == null) throw "A widget ID cache entry needs a path and identity";
    var position = find(path);
    if (position >= 0) {
      ids[position] = id;
      return;
    }
    position = -position - 1;
    if (count == paths.length) {
      paths.push(null);
      ids.push(null);
    }
    var index = count;
    while (index > position) {
      paths[index] = paths[index - 1];
      ids[index] = ids[index - 1];
      index--;
    }
    paths[position] = path;
    ids[position] = id;
    count++;
  }

  public function clear():Void {
    for (index in 0...count) {
      paths[index] = null;
      ids[index] = null;
    }
    count = 0;
  }

  /** Preserve sorted order and release stale references without resizing either backing array. */
  public function prune(mounted:Map<Int, RenderNode>, states:StateStore):Void {
    var retained = states.retainedWidgetIds(mounted);
    var previous = count, write = 0;
    for (read in 0...previous) {
      var id = ids[read];
      if (id != null && (mounted.exists(id.value) || states.contains(id) || retained.has(id.value))) {
        if (write != read) {
          paths[write] = paths[read];
          ids[write] = id;
        }
        write++;
      }
    }
    for (index in write...previous) {
      paths[index] = null;
      ids[index] = null;
    }
    count = write;
  }

  /** A miss encodes its insertion position as -index-1; lookups allocate no nullable scalar box. */
  function find(path:String):Int {
    var low = 0, high = count;
    while (low < high) {
      var middle = low + ((high - low) >> 1);
      var current = paths[middle];
      if (current == null) throw "A live widget ID cache entry has no path";
      var comparison = Reflect.compare(current, path);
      if (comparison == 0) return middle;
      if (comparison < 0) low = middle + 1;
      else high = middle;
    }
    return -low - 1;
  }
}
