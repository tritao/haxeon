package compiler.tools;

/**
 * The garbage collector's policy for a compiler process, chosen by what the process is.
 *
 * A one-shot compile is short and keeps a large live heap until it exits, so the runtime's default trigger re-marks that heap
 * many times; it collects only after every gigabyte allocated instead, trading peak memory for far fewer collections.
 * A compile server keeps the default, since its heap must stay bounded across requests.
 *
 * Declared here rather than taken from `hl.Gc`, whose stock Haxe version lacks it, so both builds of the compiler reach it.
 */
class ProcessMemory {
	static inline final ONE_SHOT_MIN_TRIGGER_BYTES = 1024.0 * 1024 * 1024;

	/** Sets the policy of a process that compiles once and exits. */
	public static function oneShotCompile():Void
		setMinTrigger(ONE_SHOT_MIN_TRIGGER_BYTES);

	@:hlNative("std", "gc_set_min_trigger") static function setMinTrigger(bytes:Float):Void {}
}
