package runtime.memory;

/** Explicit HashLink collector operations for runtime interop tests and diagnostics. */
class Gc {
	public static inline function collect():Void
		GcNative.native_gc_major();

	/** Capture one coherent snapshot of the HashLink collector counters. */
	public static inline function stats():GcStats
		return GcStats.snapshot();
}

@:hlNative("haxeon_runtime")
private class GcNative {
	public static function native_gc_major():Void {}
}
