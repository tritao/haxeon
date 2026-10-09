package hl;

#if !wasm
/** Cumulative HashLink GC counters for lightweight interval measurements. */
extern class Gc {
  @:hlNative("std", "gc_total_allocated") public static function totalAllocated():Float;
  @:hlNative("std", "gc_collections") public static function collections():Float;
  @:hlNative("std", "gc_mark_micros") public static function markMicros():Float;
  @:hlNative("std", "gc_last_pause_micros") public static function lastPauseMicros():Float;
  @:hlNative("std", "gc_max_pause_micros") public static function maxPauseMicros():Float;
  @:hlNative("std", "gc_heap_bytes") public static function heapBytes():Float;
  @:hlNative("std", "gc_allocated_since_collection") public static function allocatedSinceCollection():Float;
  /** Actual automatic collection threshold, including the allocation floor. */
  @:hlNative("std", "gc_trigger_bytes") public static function triggerBytes():Float;
  /** Experimental Linux incremental mark slice; true when complete. Unsupported systems collect fully.
      Budget is best effort, in microseconds; valid range is (0, 100000]. */
  @:hlNative("std", "gc_step") public static function step(budgetMicros:Float):Bool;
  /** Reset a process-wide soft allowance shared by automatic slices and step().
      Zero defers incremental work; -1 disables the limit. Pressure may collect fully. */
  @:hlNative("std", "gc_frame_begin") public static function beginFrame(budgetMicros:Float):Bool;
  @:hlNative("std", "gc_frame_end") public static function endFrame():Void;
  /** Remaining microseconds, or -1 when unlimited. */
  @:hlNative("std", "gc_frame_remaining") public static function frameRemaining():Float;
  @:hlNative("std", "gc_incremental_supported") public static function incrementalSupported():Bool;
  @:hlNative("std", "gc_incremental_pending") public static function incrementalPending():Bool;
  @:hlNative("std", "gc_incremental_reclaiming") public static function incrementalReclaiming():Bool;
  @:hlNative("std", "gc_major") public static function major():Void;
  /** Enables or disables automatic collections. Disabled heaps grow until re-enabled, so pair with `major()` at idle points. */
  @:hlNative("std", "gc_enable") public static function enable(enabled:Bool):Void;
  /** Fraction of the heap that may be allocated between collections (default 0.2, clamped to 0.05...4). */
  @:hlNative("std", "gc_set_mark_threshold") public static function setMarkThreshold(fraction:Float):Void;
  @:hlNative("std", "gc_get_mark_threshold") public static function markThreshold():Float;
  @:hlNative("std", "gc_dump_memory") public static function dump(path:hl.Bytes):Void;
  /** Counts every allocation by type from now on; `stackEveryBytes` > 0 also samples call stacks once per that many allocated bytes. */
  @:hlNative("std", "gc_census_start") public static function censusStart(stackEveryBytes:Int):Void;
  @:hlNative("std", "gc_census_stop") public static function censusStop():Void;
  @:hlNative("std", "gc_census_reset") public static function censusReset():Void;
  /** Writes the census as JSON (per-type counts and bytes, sampled stacks with resolved names) to a UTF-8 path. */
  @:hlNative("std", "gc_census_dump") public static function censusDump(path:hl.Bytes):Void;
}
#else
/**
 * Wasm has no HashLink collector to control or observe: Wasm32 collects on its own allocation
 * budget and Wasm GC leaves collection to the engine. Controls are accepted and ignored, and
 * counters read zero, so profiling code runs unchanged but measures nothing.
 */
class Gc {
	static var threshold = 0.2;

	public static function totalAllocated():Float
		return 0.0;

	public static function collections():Float
		return 0.0;

	public static function markMicros():Float
		return 0.0;

	public static function lastPauseMicros():Float
		return 0.0;

	public static function maxPauseMicros():Float
		return 0.0;

	public static function heapBytes():Float
		return 0.0;

	public static function allocatedSinceCollection():Float
		return 0.0;

	public static function beginFrame(budgetMicros:Float):Bool return budgetMicros == -1.0 || (budgetMicros >= 0.0 && budgetMicros <= 100000.0);
	public static function endFrame():Void {}
	public static function frameRemaining():Float return -1.0;
	public static function triggerBytes():Float return 0.0;
	public static function incrementalSupported():Bool return false;
	public static function incrementalPending():Bool return false;
	public static function incrementalReclaiming():Bool return false;
	public static function step(budgetMicros:Float):Bool return budgetMicros > 0.0 && budgetMicros <= 100000.0;

	public static function major():Void {}

	public static function enable(enabled:Bool):Void {}

	/** Remembered with HashLink's clamping so a read returns what was set; it has no effect. */
	public static function setMarkThreshold(fraction:Float):Void
		threshold = fraction < 0.05 ? 0.05 : fraction > 4.0 ? 4.0 : fraction;

	public static function markThreshold():Float
		return threshold;

	public static function dump(path:hl.Bytes):Void {}

	public static function censusStart(stackEveryBytes:Int):Void {}

	public static function censusStop():Void {}

	public static function censusReset():Void {}

	public static function censusDump(path:hl.Bytes):Void {}
}
#end
