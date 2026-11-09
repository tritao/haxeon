package compiler.compilation;

/**
 * The garbage collector's mark threshold for the build that is about to run, in one place. A collection starts once the bytes
 * allocated since the last one exceed this fraction of the heap, so a higher value spends less time marking and a lower one holds less
 * dead memory at the peak.
 *
 * - A cold build allocates for a long time and keeps most of it, so marking early only repeats work: 0.4.
 * - A warm build (no-op or edit) runs in a worker whose heap already holds the last build, so the same slack is pure
 *   headroom above a large live set: 0.2. Measured in `COMPILER_MEMORY.md`: the edit peak drops by about 2 GB.
 *
 * `HL_GC_MARK_THRESHOLD` (set by the launcher) is only the value the process starts with.
 */
class GcPolicy {
	public static inline final COLD_BUILD = 0.4;
	public static inline final WARM_BUILD = 0.2;

	/** `warm` is true when the worker has compiled before. */
	public static function beginBuild(warm:Bool):Void {
		var threshold = warm ? WARM_BUILD : COLD_BUILD;
		#if haxeon
		hl.Gc.setMarkThreshold(threshold);
		#elseif hl
		setMarkThreshold(threshold);
		#end
	}

	// The compiler is also built with the Haxe standard library, whose hl.Gc has no setter; the primitive is in the runtime either way.
	#if (hl && !haxeon)
	@:hlNative("std", "gc_set_mark_threshold")
	static function setMarkThreshold(fraction:Float):Void {}
	#end
}
