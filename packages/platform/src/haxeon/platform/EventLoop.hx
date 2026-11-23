package haxeon.platform;

import haxeon.platform.event.EventPump;

/** One platform event cycle for applications and hosts that supply their own frame scheduling. */
class EventLoop {
	final events:EventPump;

	public function new(events:EventPump) {
		this.events = events;
	}

	/** Drains a bounded batch without blocking. */
	public function drain(?keepPolling:Void->Bool):Bool {
		var hadEvent = false;
		for (_ in 0...64) {
			if ((keepPolling != null && !keepPolling()) || !events.poll())
				break;
			hadEvent = true;
		}
		return hadEvent;
	}

	/** Drains a batch, then optionally waits for the timeout selected by the caller. */
	public function step(afterPoll:Bool->Null<Float>):Bool {
		var waitSeconds = afterPoll(drain());
		if (waitSeconds == null)
			return false;
		events.wait(waitSeconds);
		return true;
	}

	/** Drives a desktop session until its current iteration reports that it is finished. */
	public static function run(tick:Void->Bool):Void {
		while (tick()) {}
	}
}
