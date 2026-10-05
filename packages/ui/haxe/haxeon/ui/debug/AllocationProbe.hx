package haxeon.ui.debug;

/** Cumulative bytes allocated by the runtime, for attributing allocation to frame phases; 0 where the runtime has no counter. */
class AllocationProbe {
	public static inline function now():Float {
		#if wasm
		return 0.0;
		#else
		return hl.Gc.totalAllocated();
		#end
	}
}
