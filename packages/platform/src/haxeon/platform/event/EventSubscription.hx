package haxeon.platform.event;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.internal.DisposalRegistry;

/** One registration in the runtime event pump. */
class EventSubscription implements Disposable {
	final events:EventPump;
	final remove:Void->Void;
	var owner:Null<DisposalRegistration>;
	var disposed = false;

	@:allow(haxeon.platform.event.EventPump)
	private function new(events:EventPump, remove:Void->Void) {
		this.events = events;
		this.remove = remove;
	}

	@:allow(haxeon.platform.Window, haxeon.platform.Surface)
	function ownedBy(registry:DisposalRegistry):EventSubscription {
		owner = registry.register(dispose);
		return this;
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		remove();
		if (owner != null) owner.detach();
		owner = null;
	}

	public function isDisposed():Bool
		return disposed || events.isDisposed();
}
