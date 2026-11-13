import haxeon.ui.core.IdSet;

/** Deletion repairs wraparound clusters and keeps removals allocation free after growth. */
class IdSetMain {
  static function main():Int {
    var set = new IdSet(16);
    for (id in [15, 31, 47, 63]) set.add(id);
    if (!set.remove(31) || set.remove(31) || set.count() != 3 || !set.has(15) || !set.has(47) || !set.has(63)) return 1;
    if (!set.remove(15) || !set.has(47) || !set.has(63) || set.count() != 2) return 2;
    set.clear();
    for (index in 0...1024) set.add(index * 16 + 15);
    #if !wasm
    var before = hl.Gc.totalAllocated();
    #end
    for (index in 0...1024) if (index % 3 == 0 && !set.remove(index * 16 + 15)) return 3;
    #if !wasm
    if (hl.Gc.totalAllocated() != before) return 4;
    #end
    for (index in 0...1024) if (set.has(index * 16 + 15) != (index % 3 != 0)) return 5;
    if (set.count() != 682) return 6;
    set.clear();
    return set.count() == 0 && !set.has(31) && set.add(31) && set.remove(31) && !set.remove(31) ? 42 : 7;
  }
}
