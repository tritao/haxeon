package compiler.compilation;

typedef AllocationSnapshot = {
	final bytes:Float;
	final count:Float;
	final collections:Float;
	final markMicros:Float;
}

typedef PhaseAllocation = {
	final name:String;
	final bytes:Float;
	final count:Float;
	final collections:Float;
	final markMicros:Float;
}

/** Lightweight counters at compiler phase boundaries. */
class AllocationMeter {
	public static function sample():AllocationSnapshot {
		#if hl
		var bytes = 0.0, count = 0.0, collections = 0.0, markMicros = 0.0;
		detailedStats(bytes, count, collections, markMicros);
		return {
			bytes: bytes,
			count: count,
			collections: collections,
			markMicros: markMicros
		};
		#else
		return {
			bytes: 0.0,
			count: 0.0,
			collections: 0.0,
			markMicros: 0.0
		};
		#end
	}

	public static function delta(name:String, before:AllocationSnapshot, after:AllocationSnapshot):PhaseAllocation {
		return {
			name: name,
			bytes: after.bytes - before.bytes,
			count: after.count - before.count,
			collections: after.collections - before.collections,
			markMicros: after.markMicros - before.markMicros
		};
	}

	#if hl
	@:hlNative("std", "gc_detailed_stats")
	static function detailedStats(bytes:hl.Ref<Float>, count:hl.Ref<Float>, collections:hl.Ref<Float>, markMicros:hl.Ref<Float>):Void {}
	#end
}
