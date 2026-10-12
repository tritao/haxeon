package haxeon.audio;

import haxe.Int64;
import nativekit.ffi.NativeKitAudioTypes.NativeAudioDiagnostics;

/** Callback timing observations, not hardware/backend XRUN counters. */
class AudioDiagnostics {
  public final enabled:Bool;
  /** False when this callback scope has no monotonic wall clock. */
  public final timingAvailable:Bool;
  public final callbacks:Int64;
  public final renderedFrames:Int64;
  public final budgetOverruns:Int64;
  public final lateCallbackGaps:Int64;
  public final shortReads:Int64;
  public final readErrors:Int64;
  public final maxCallbackMs:Float;
  public final maxGapMs:Float;
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
