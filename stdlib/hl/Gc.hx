package hl;

/** Cumulative HashLink GC counters for lightweight interval measurements. */
extern class Gc {
  @:hlNative("std", "gc_total_allocated") public static function totalAllocated():Float;
  @:hlNative("std", "gc_collections") public static function collections():Float;
  @:hlNative("std", "gc_mark_micros") public static function markMicros():Float;
  @:hlNative("std", "gc_last_pause_micros") public static function lastPauseMicros():Float;
  @:hlNative("std", "gc_max_pause_micros") public static function maxPauseMicros():Float;
  @:hlNative("std", "gc_heap_bytes") public static function heapBytes():Float;
  @:hlNative("std", "gc_major") public static function major():Void;
  /** Enables or disables automatic collections. Disabled heaps grow until re-enabled, so pair with `major()` at idle points. */
  @:hlNative("std", "gc_enable") public static function enable(enabled:Bool):Void;
  /** Fraction of the heap that may be allocated between collections (default 0.2, clamped to 0.05...4). */
  @:hlNative("std", "gc_set_mark_threshold") public static function setMarkThreshold(fraction:Float):Void;
  @:hlNative("std", "gc_get_mark_threshold") public static function markThreshold():Float;
  @:hlNative("std", "gc_dump_memory") public static function dump(path:hl.Bytes):Void;
}
