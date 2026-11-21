package compiler.core;

/**
 * Collections at the ends of a compile's phases (docs/design/ARENAS.md, "Long-term goal"). At the end of a phase its data is
 * dead and the live set is smallest, so a collection there frees the most; the byte trigger stays as the safety net for
 * large inputs. A boundary collects only once half a trigger was allocated since the last collection, so collections stay
 * at least half a trigger apart.
 */
class PhaseCollections {
	/** Ends phase `name`: collects when `enabled` (`CompileOptions.phaseCollections`) and enough was allocated since the last collection. */
	public static function end(name:String, enabled:Bool):Void {
		// The boundary's mark: a census there (`HAXEON_PEAK_CENSUS=ir-end`) is the phase's live data, which the performance guard gates.
		if (PeakProbe.on())
			PeakProbe.mark(name + "-end");
		#if hl
		if (!enabled || allocatedSinceCollection() * 2 < triggerBytes())
			return;
		collect();
		if (PeakProbe.on())
			PeakProbe.mark("collected-" + name);
		#end
	}

	#if hl
	@:hlNative("std", "gc_allocated_since_collection") static function allocatedSinceCollection():Float
		return 0;

	@:hlNative("std", "gc_trigger_bytes") static function triggerBytes():Float
		return 0;

	@:hlNative("std", "gc_major") static function collect():Void {}
	#end
}
