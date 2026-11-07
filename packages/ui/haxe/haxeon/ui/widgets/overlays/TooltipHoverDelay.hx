package haxeon.ui.widgets.overlays;

import haxeon.ui.animation.DelayedAnimation;
import haxeon.ui.animation.RetainedAnimation;
import haxeon.ui.animation.AnimationScheduler;

/** Waiting for a hint changes no layout or paint until the deadline updates its visibility state. */
class TooltipHoverDelay implements DelayedAnimation implements RetainedAnimation {
	final scheduler:AnimationScheduler;
	final changed:Bool->Void;
	var remaining:Float = 0;
	var pending:Bool = false;
	var disposed:Bool = false;
	public var durationSeconds:Float;
	public function new(scheduler:AnimationScheduler, changed:Bool->Void, delaySeconds:Float = 0.8) {
		this.durationSeconds = delaySeconds;
		this.scheduler = scheduler; this.changed = changed;
	}
	public function start():Void {
		if (disposed) return;
		pending = true;
		remaining = durationSeconds;
		changed(false);
		scheduler.track(this);
	}
	public function cancel():Void {
		pending = false;
		remaining = 0;
		scheduler.remove(this);
		changed(false);
	}
	public function delaySeconds():Float return pending ? Math.max(0, remaining) : 0;
	public function advance(deltaSeconds:Float):Bool {
		if (!pending || disposed) return false;
		remaining -= deltaSeconds;
		if (remaining > 0) return true;
		pending = false;
		changed(true);
		return false;
	}
	public function dispose():Void { disposed = true; pending = false; scheduler.remove(this); }
}
