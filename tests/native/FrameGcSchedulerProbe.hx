import haxeon.ui.host.FrameGcScheduler;
import hl.Gc;

class FrameGcSchedulerProbe {
	static function main() {
		var scheduler = new FrameGcScheduler(true, true, 1000.0);
		if (!scheduler.incremental)
			throw "incremental unavailable";
		scheduler.beginFrame();
		scheduler.beginFrame();
		var keep = new haxe.ds.Vector<Dynamic>(1000000);
		scheduler.endFrame();
		scheduler.endFrame();
		// Force a pending cycle without depending on host allocation-pressure thresholds.
		Gc.enable(false);
		Gc.step(0.001);
		if (!Gc.incrementalPending())
			throw "expected pending collection";
		scheduler.beginFrame();
		scheduler.endFrame();
		if (scheduler.incrementalSlices != 1)
			throw "frame did not advance marking";
		scheduler.idle();
		if (Gc.incrementalPending() || scheduler.idleCollections != 1)
			throw "idle did not complete collection";
		if (keep.length != 1000000)
			throw "live array lost";
		var bounded = new FrameGcScheduler(true, true, 0.001);
		bounded.beginFrame();
		Gc.step(1000.0);
		if (Gc.frameRemaining() != 0.0) throw "step did not consume frame allowance";
		bounded.beginFrame();
		if (Gc.frameRemaining() != 0.0) throw "duplicate begin reset allowance";
		bounded.endFrame();
		bounded.endFrame();
		if (bounded.incrementalSlices != 0 || Gc.frameRemaining() != -1.0) throw "end added another slice or leaked allowance";
		bounded.idle();
		Sys.println("PASS: frame-boundary incremental slice and idle completion");
	}
}
