package hl;

/** Cumulative HashLink GC counters for lightweight interval measurements. */
extern class Gc {
  @:hlNative("std", "gc_total_allocated") public static function totalAllocated():Float;
  @:hlNative("std", "gc_collections") public static function collections():Float;
  @:hlNative("std", "gc_mark_micros") public static function markMicros():Float;
  @:hlNative("std", "gc_major") public static function major():Void;
  @:hlNative("std", "gc_dump_memory") public static function dump(path:hl.Bytes):Void;
}
