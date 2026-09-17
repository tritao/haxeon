package runtime.memory;

/** Immutable point-in-time counters reported by the HashLink collector. */
abstract GcStats(hl.Abstract<"haxeon_gc_stats">) {
	/** Capture all counters from one collector snapshot. */
	public static inline function snapshot():GcStats
		return cast GcStatsNative.native_gc_stats_snapshot();

	/** Total bytes allocated since collector startup. */
	public inline function totalAllocated():Int64
		return GcStatsNative.native_gc_stats_total_allocated(cast this);

	/** Number of allocations since collector startup. */
	public inline function allocationCount():Int64
		return GcStatsNative.native_gc_stats_allocation_count(cast this);

	/** Bytes currently reserved by the collector's pages. */
	public inline function heapBytes():Int64
		return GcStatsNative.native_gc_stats_heap_bytes(cast this);

	/** Number of completed major collections. */
	public inline function collectionCount():Int64
		return GcStatsNative.native_gc_stats_collection_count(cast this);

	/** Accumulated collector mark time in microseconds when available. */
	public inline function markMicros():Int64
		return GcStatsNative.native_gc_stats_mark_micros(cast this);
}

@:hlNative("haxeon_runtime")
private class GcStatsNative {
	public static function native_gc_stats_snapshot():hl.Abstract<"haxeon_gc_stats">
		return null;

	public static function native_gc_stats_total_allocated(stats:hl.Abstract<"haxeon_gc_stats">):Int64
		return 0;

	public static function native_gc_stats_allocation_count(stats:hl.Abstract<"haxeon_gc_stats">):Int64
		return 0;

	public static function native_gc_stats_heap_bytes(stats:hl.Abstract<"haxeon_gc_stats">):Int64
		return 0;

	public static function native_gc_stats_collection_count(stats:hl.Abstract<"haxeon_gc_stats">):Int64
		return 0;

	public static function native_gc_stats_mark_micros(stats:hl.Abstract<"haxeon_gc_stats">):Int64
		return 0;
}
