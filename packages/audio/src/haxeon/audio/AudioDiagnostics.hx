package haxeon.audio;

import haxe.Int64;
import nativekit.ffi.NativeKitAudioTypes.NativeAudioDiagnostics;

/** Callback timing observations, not hardware/backend XRUN counters. */
class AudioDiagnostics {
	/** Whether the callback has a monotonic clock to measure with. */
	public final enabled:Bool;
	/** False when this callback scope has no monotonic wall clock. */
	public final timingAvailable:Bool;

	/** How many audio callbacks ran. */
	public final callbacks:Int64;

	/** How many frames they rendered. */
	public final renderedFrames:Int64;

	/** How many callbacks took longer than their block's duration. */
	public final budgetOverruns:Int64;

	/** How many gaps between callbacks were longer than a block. */
	public final lateCallbackGaps:Int64;

	/** How many callbacks produced fewer frames than asked. */
	public final shortReads:Int64;

	/** How many callbacks failed to read their source. */
	public final readErrors:Int64;

	/** The longest callback, in milliseconds. */
	public final maxCallbackMs:Float;

	/** The longest gap between callbacks, in milliseconds. */
	public final maxGapMs:Float;

	/** The last block's duration, the time a callback has, in milliseconds. */
	public final lastBudgetMs:Float;

	@:allow(haxeon.audio.Mixer)
	private function new(value:NativeAudioDiagnostics) {
		enabled = value.get_enabled();
		callbacks = value.get_callback_count();
		renderedFrames = value.get_rendered_frames();
		budgetOverruns = value.get_budget_overruns();
		lateCallbackGaps = value.get_late_callback_gaps();
		shortReads = value.get_short_reads();
		readErrors = value.get_read_errors();
		maxCallbackMs = value.get_max_callback_ms();
		maxGapMs = value.get_max_gap_ms();
		lastBudgetMs = value.get_last_budget_ms();
		timingAvailable = lastBudgetMs > 0;
	}
}
