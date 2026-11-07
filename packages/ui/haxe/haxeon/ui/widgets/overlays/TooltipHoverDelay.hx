package haxeon.ui.widgets.overlays;

import haxeon.ui.animation.DelayedAnimation;
import haxeon.ui.animation.AnimationScheduler;

class TooltipHoverDelay implements DelayedAnimation {
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
		scheduler.remove(this);
		pending = false;
		remaining = 0;
		changed(false);
	}
	public function advance(deltaSeconds:Float):Bool {
		if (!pending || disposed) return false;
		remaining -= deltaSeconds;
		if (remaining > 0) return true;
		pending = false;
		changed(true);
		return false;
	}
	public function delaySeconds():Float return pending ? Math.max(0, remaining) : 0;
	public function dispose():Void { scheduler.remove(this); disposed = true; pending = false; }
}
