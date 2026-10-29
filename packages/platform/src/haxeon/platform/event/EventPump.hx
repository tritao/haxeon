package haxeon.platform.event;

import haxeon.platform.BindingError;
import haxeon.platform.Runtime;
import haxeon.platform.async.Requests;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.NativeEvent;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Event;

/** The managed owner of NativeKit's native event queue. */
class EventPump {
	public final requests:Requests;
	final listeners:Array<PlatformEvent->Void> = [];
	var disposed:Bool = false;

	@:allow(Runtime)
	@:allow(ShowcaseDesktop)
	@:allow(ShowcaseWeb)
	private function new() {
		requests = new Requests();
	}

	/** Polls and releases one native event, then routes its managed snapshot. */
	public function poll():Bool {
		ensureLive();
		var polled = NativeKit.nk_poll_event_checked(new Event());
		var event = new NativeEvent(polled);
		var value = event.take();
		var hasEvent = switch value {
			case None: false;
			case _: true;
		};
		if (hasEvent)
			dispatch(value);
		return hasEvent;
	}

	/** Pumps native events and waits until input or the timeout expires. */
	public function wait(timeoutSeconds:Float):Void {
		ensureLive();
		NativeKit.nk_wait_events_timeout_checked(timeoutSeconds);
	}

	/** Adds an observer which receives decoded, fully managed events. */
	public function listen(listener:PlatformEvent->Void):EventSubscription {
		ensureLive();
		if (listener == null)
			throw BindingError.invalidArgument("EventPump.listen", "NativeKit event listeners cannot be null");
		listeners.push(listener);
		return new EventSubscription(this, listener);
	}

	/** Reports whether this runtime's event pump has been shut down. */
	public function isDisposed():Bool
		return disposed;

	/** Removes one listener when its subscription is disposed. */
	@:allow(EventSubscription)
	private function removeListener(listener:PlatformEvent->Void):Bool
		return listeners.remove(listener);

	/** Stops the pump after its owning runtime shuts down. */
	@:allow(Runtime)
	@:allow(ShowcaseDesktop)
	@:allow(ShowcaseWeb)
	private function runtimeShutdown():Void {
		disposed = true;
		listeners.resize(0);
		requests.runtimeShutdown();
	}

	/** Routes a decoded value through the same request and listener path as poll(). */
	public function dispatch(value:PlatformEvent):Void {
		ensureLive();
		if (value == null)
			return;
		switch value {
			case None:
				return;
			case _:
		}

		var snapshot = listeners.copy();
		var failure:Dynamic = null;
		try {
			requests.handle(value);
		} catch (error:Dynamic) {
			failure = error;
		}
		for (listener in snapshot) {
			try {
				listener(value);
			} catch (error:Dynamic) {
				if (failure == null)
					failure = error;
			}
		}
		if (failure != null)
			throw failure;
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("EventPump.ensureLive", "NativeKit event pump has been disposed with its runtime");
	}
}
