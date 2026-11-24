package compiler.tools;

/**
 * The garbage collector's policy for a compiler process, chosen by what the process is.
 *
 * A one-shot compile is short and keeps a large live heap until it exits, so the runtime's default trigger re-marks that heap
 * many times; it collects only after every gigabyte allocated instead, trading peak memory for far fewer collections.
 *
 * A compile server keeps its session live across requests, so its memory is that session plus what a request allocates. It
 * collects once after each compile's response, off the edit's path, and during a request only once it has allocated a fixed
 * fraction of what that collection found alive: a small edit then runs without a collection, and the peak stays a bounded
 * multiple of the session. A heap-sized trigger would instead grow with the garbage the heap keeps pages for.
 *
 * Declared here rather than taken from `hl.Gc`, whose stock Haxe version lacks it, so both builds of the compiler reach it.
 */
class ProcessMemory {
	static inline final ONE_SHOT_MIN_TRIGGER_BYTES = 1024.0 * 1024 * 1024;

	/** A server's trigger: the bytes allocated since the last collection, as a multiple of what that collection found alive. */
	static inline final SERVER_LIVE_RATIO = 0.75;

	/** Sets the policy of a process that compiles once and exits. */
	public static function oneShotCompile():Void
		setMinTrigger(ONE_SHOT_MIN_TRIGGER_BYTES);

	/** Sets the policy of a compile server, before its first request. */
	public static function compileServer():Void
		setLiveRatio(SERVER_LIVE_RATIO);

	/** Collects between a server's requests, once a compile's response is out, so the next request starts from a fresh trigger. */
	public static function betweenRequests():Void
		collect();

	@:hlNative("std", "gc_set_min_trigger") static function setMinTrigger(bytes:Float):Void {}

	@:hlNative("std", "gc_set_live_ratio") static function setLiveRatio(ratio:Float):Void {}

	@:hlNative("std", "gc_major") static function collect():Void {}
}
