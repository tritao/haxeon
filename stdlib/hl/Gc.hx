package hl;

#if !wasm
/** `stats` as an array: bytes allocated in total, allocations made, and current heap bytes. */
@:hlNative("haxeon_runtime", "__gc_stats")
extern function gcStats():Array<Float>;

/**
 * HashLink's counters, as Haxe's hl.Gc.stats: bytes allocated in total, allocations made, and current heap bytes. A module
 * function of hl.Gc, so it is called as `hl.Gc.stats()`, beside the natives the extern class binds.
 */
function stats():{totalAllocated:Float, allocationCount:Float, currentMemory:Float} {
	var values = gcStats();
	return {totalAllocated: values[0], allocationCount: values[1], currentMemory: values[2]};
}

/** HashLink's garbage collector: its counters, for measuring an interval, and its controls. */
extern class Gc {
	/** Bytes allocated since the process started. */
	@:hlNative("std", "gc_total_allocated") public static function totalAllocated():Float;

	/** Major collections since the process started. */
	@:hlNative("std", "gc_collections") public static function collections():Float;

	/** Microseconds spent marking, in total. */
	@:hlNative("std", "gc_mark_micros") public static function markMicros():Float;

	/** How long the last collection paused the program, in microseconds. */
	@:hlNative("std", "gc_last_pause_micros") public static function lastPauseMicros():Float;

	/** The longest a collection has paused the program, in microseconds. */
	@:hlNative("std", "gc_max_pause_micros") public static function maxPauseMicros():Float;

	/** Bytes the heap holds in pages now. */
	@:hlNative("std", "gc_heap_bytes") public static function heapBytes():Float;

	/** Bytes allocated since the last collection. */
	@:hlNative("std", "gc_allocated_since_collection") public static function allocatedSinceCollection():Float;

	/** Actual automatic collection threshold, including the allocation floor. */
	@:hlNative("std", "gc_trigger_bytes") public static function triggerBytes():Float;

	/** Experimental Linux incremental mark slice; true when complete. Unsupported systems collect fully.
      Budget is best effort, in microseconds; valid range is (0, 100000]. */
	@:hlNative("std", "gc_step") public static function step(budgetMicros:Float):Bool;

	/** Reset a process-wide soft allowance shared by automatic slices and step().
      Zero defers incremental work; -1 disables the limit. Pressure may collect fully. */
	@:hlNative("std", "gc_frame_begin") public static function beginFrame(budgetMicros:Float):Bool;

	/** Ends the frame `beginFrame` began, dropping its allowance. */
	@:hlNative("std", "gc_frame_end") public static function endFrame():Void;

	/** Remaining microseconds, or -1 when unlimited. */
	@:hlNative("std", "gc_frame_remaining") public static function frameRemaining():Float;

	/** Whether incremental collection works on this system. */
	@:hlNative("std", "gc_incremental_supported") public static function incrementalSupported():Bool;

	/** Whether an incremental collection has started and not finished marking. */
	@:hlNative("std", "gc_incremental_pending") public static function incrementalPending():Bool;

	/** Whether an incremental collection has finished marking and is reclaiming memory. */
	@:hlNative("std", "gc_incremental_reclaiming") public static function incrementalReclaiming():Bool;

	/** Collects now, fully. */
	@:hlNative("std", "gc_major") public static function major():Void;

	/** Enables or disables automatic collections. Disabled heaps grow until re-enabled, so pair with `major()` at idle points. */
	@:hlNative("std", "gc_enable") public static function enable(enabled:Bool):Void;

	/** Fraction of the heap that may be allocated between collections (default 0.2, clamped to 0.05...4). */
	@:hlNative("std", "gc_set_mark_threshold") public static function setMarkThreshold(fraction:Float):Void;

	/** The fraction `setMarkThreshold` set. */
	@:hlNative("std", "gc_get_mark_threshold") public static function markThreshold():Float;

	/** The least allocation between two major collections, in bytes. A short process with a large live heap collects far
		less often with a larger one, for that much more peak memory. */
	@:hlNative("std", "gc_set_min_trigger") public static function setMinTrigger(bytes:Float):Void;

	/** The bytes `setMinTrigger` set. */
	@:hlNative("std", "gc_get_min_trigger") public static function minTrigger():Float;

	/** Writes a heap dump to `fileName`, as Haxe's hl.Gc.dumpMemory. */
	@:hlNative("haxeon_runtime",
		"__gc_dump_memory") public static function dumpMemory(fileName:String = "hlmemory.dump"):Void;
	/** Counts every allocation by type from now on; `stackEveryBytes` > 0 also samples call stacks once per that many allocated bytes. */
	@:hlNative("std", "gc_census_start") public static function censusStart(stackEveryBytes:Int):Void;

	/** Stops counting allocations, keeping what was counted. */
	@:hlNative("std", "gc_census_stop") public static function censusStop():Void;

	/** Clears what the census counted. */
	@:hlNative("std", "gc_census_reset") public static function censusReset():Void;

	/** Writes the census as JSON (per-type counts and bytes, sampled stacks with resolved names) to the file at `path`. */
	@:hlNative("haxeon_runtime", "__gc_census_dump") public static function censusDump(path:String):Void;
}
#else
/**
 * Wasm has no HashLink collector to control or observe: Wasm32 collects on its own allocation
 * budget and Wasm GC leaves collection to the engine. Controls are accepted and ignored, and
 * counters read zero, so profiling code runs unchanged but measures nothing.
 */
class Gc {
	static var threshold = 0.2;
	static var trigger = 64.0 * 1024 * 1024;

	/** Bytes allocated since the process started. */
	public static function totalAllocated():Float
		return 0.0;

	/** Major collections since the process started. */
	public static function collections():Float
		return 0.0;

	/** Microseconds spent marking, in total. */
	public static function markMicros():Float
		return 0.0;

	/** How long the last collection paused the program, in microseconds. */
	public static function lastPauseMicros():Float
		return 0.0;

	/** The longest a collection has paused the program, in microseconds. */
	public static function maxPauseMicros():Float
		return 0.0;

	/** Bytes the heap holds in pages now. */
	public static function heapBytes():Float
		return 0.0;

	/** Bytes allocated since the last collection. */
	public static function allocatedSinceCollection():Float
		return 0.0;

	/**
	 * Reset a process-wide soft allowance shared by automatic slices and step(). Zero defers incremental work; -1
	 * disables the limit. Pressure may collect fully.
	 */
	public static function beginFrame(budgetMicros:Float):Bool return budgetMicros == -1.0
		|| (budgetMicros >= 0.0 && budgetMicros <= 100000.0);

	/** Ends the frame `beginFrame` began, dropping its allowance. */
	public static function endFrame():Void {}

	/** Remaining microseconds, or -1 when unlimited. */
	public static function frameRemaining():Float return -1.0;

	/** Actual automatic collection threshold, including the allocation floor. */
	public static function triggerBytes():Float return 0.0;

	/** Whether incremental collection works on this system. */
	public static function incrementalSupported():Bool return false;

	/** Whether an incremental collection has started and not finished marking. */
	public static function incrementalPending():Bool return false;

	/** Whether an incremental collection has finished marking and is reclaiming memory. */
	public static function incrementalReclaiming():Bool return false;

	/**
	 * Experimental Linux incremental mark slice; true when complete. Unsupported systems collect fully. Budget is best
	 * effort, in microseconds; valid range is (0, 100000].
	 */
	public static function step(budgetMicros:Float):Bool return budgetMicros > 0.0 && budgetMicros <= 100000.0;

	/** Collects now, fully. */
	public static function major():Void {}

	/**
	 * Enables or disables automatic collections. Disabled heaps grow until re-enabled, so pair with `major()` at idle
	 * points.
	 */
	public static function enable(enabled:Bool):Void {}

	/** Remembered with HashLink's clamping so a read returns what was set; it has no effect. */
	public static function setMarkThreshold(fraction:Float):Void
		threshold = fraction < 0.05 ? 0.05 : fraction > 4.0 ? 4.0 : fraction;

	/** The fraction `setMarkThreshold` set. */
	public static function markThreshold():Float
		return threshold;

	/** Remembered so a read returns what was set; it has no effect. */
	public static function setMinTrigger(bytes:Float):Void
		trigger = bytes < 0 ? 0 : bytes;

	/** The bytes `setMinTrigger` set. */
	public static function minTrigger():Float
		return trigger;

	/** Writes a heap dump to `fileName`, as Haxe's hl.Gc.dumpMemory. */
	public static function dumpMemory(fileName:String = "hlmemory.dump"):Void {}

	/** HashLink's counters, as Haxe's hl.Gc.stats: all zero on Wasm. */
	public static function stats():{totalAllocated:Float, allocationCount:Float, currentMemory:Float} return {
		totalAllocated: 0.0,
		allocationCount: 0.0,
		currentMemory: 0.0
	};

	/**
	 * Counts every allocation by type from now on; `stackEveryBytes` > 0 also samples call stacks once per that many
	 * allocated bytes.
	 */
	public static function censusStart(stackEveryBytes:Int):Void {}

	/** Stops counting allocations, keeping what was counted. */
	public static function censusStop():Void {}

	/** Clears what the census counted. */
	public static function censusReset():Void {}

	/**
	 * Writes the census as JSON (per-type counts and bytes, sampled stacks with resolved names) to the file at `path`.
	 */
	public static function censusDump(path:String):Void {}
}
#end
