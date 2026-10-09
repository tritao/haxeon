package haxeon.ui.host;

import hl.Gc;

/**
 * Keeps garbage collections out of frames. HashLink collects stop-the-world whenever allocation since
 * the last collection passes a fraction of the heap, which lands the pause inside whichever frame
 * happened to allocate. While a frame renders, automatic collection is off; the collection runs
 * afterwards, immediately when allocation pressure has passed `forceAtPressure` times the normal
 * trigger (so continuous animation cannot grow the heap without bound), or when the host goes idle.
 * With HL_GC_INCREMENTAL=1, frame boundaries advance marking in best-effort slices;
 * the allowance is shared with explicit steps during rendering. Idle and emergency
 * collections still finish synchronously.
 */
class FrameGcScheduler {
	/** Pressure is bytes allocated since the last collection over the collector's own trigger size. */
	public static inline final IdlePressure = 0.5;

	public static inline final ForcePressure = 3.0;

	public final enabled:Bool;
	public var idleCollections(default, null):Int = 0;
	public var forcedCollections(default, null):Int = 0;
	public final incremental:Bool;
	public final sliceMicros:Float;
	public var incrementalSlices(default, null):Int = 0;
	var inFrame = false;

	public function new(enabled:Bool, incremental:Bool = false, sliceMicros:Float = 1000.0) {
		this.enabled = enabled;
		this.incremental = enabled && incremental && Gc.incrementalSupported();
		this.sliceMicros = sliceMicros > 0.0 && sliceMicros <= 100000.0 ? sliceMicros : 1000.0;
	}

	/** `MATERIA_FRAME_GC=0` turns frame-boundary collection off so it can be compared against the default. */
	public static function fromEnvironment():FrameGcScheduler {
		var setting = Sys.getEnv("MATERIA_FRAME_GC");
		return new FrameGcScheduler(setting == null || setting != "0", Sys.getEnv("HL_GC_INCREMENTAL") == "1");
	}

	public function beginFrame():Void {
		if (!enabled || inFrame)
			return;
		inFrame = true;
		if (incremental)
			Gc.beginFrame(sliceMicros);
		Gc.enable(false);
	}

	/** Safe to call repeatedly and after a failed frame. */
	public function endFrame():Void {
		if (!enabled || !inFrame)
			return;
		inFrame = false;
		Gc.enable(true);
		try {
			if (pressure() >= ForcePressure) {
				forcedCollections++;
				Gc.major();
			} else if (incremental && Gc.frameRemaining() > 0.0 && (Gc.incrementalPending() || pressure() >= IdlePressure)) {
				incrementalSlices++;
				Gc.step(sliceMicros);
			}
		} catch (error:Dynamic) {
			if (incremental) Gc.endFrame();
			throw error;
		}
		if (incremental) Gc.endFrame();
	}

	/** Called when nothing is pending: collect now rather than inside a later frame. */
	public function idle():Void {
		if (!enabled || inFrame || (!Gc.incrementalPending() && pressure() < IdlePressure))
			return;
		idleCollections++;
		Gc.major();
	}

	function pressure():Float {
		var trigger = Gc.triggerBytes();
		return trigger <= 0.0 ? 0.0 : Gc.allocatedSinceCollection() / trigger;
	}
}
