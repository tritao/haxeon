package haxeon.platform.event;

import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;

/** One listener registration owned by a NativeKit event pump. */
class EventSubscription {
	final events:EventPump;
	final listener:PlatformEvent->Void;
	var disposed:Bool = false;

	@:allow(EventPump)
	private function new(events:EventPump, listener:PlatformEvent->Void) {
		this.events = events;
		this.listener = listener;
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		events.removeListener(listener);
	}

	public function isDisposed():Bool
		return disposed || events.isDisposed();
}
