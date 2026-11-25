package haxeon.platform.event;

import haxeon.platform.BindingError;
import haxeon.platform.Runtime;
import haxeon.platform.async.Requests;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Event;
import nativekit.ffi.NativeKitTypes.Handle;

/** The managed owner of NativeKit's native event queue. */
class EventPump {
	public final requests:Requests;
	final listeners:Array<PlatformEvent->Void> = [];
	final sourceListeners:Map<Int, Array<SourceRoute>> = [];
	var disposed:Bool = false;

	@:allow(haxeon.platform.Runtime)
	@:allow(ShowcaseDesktop)
	@:allow(AndroidUiHost)
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
		return new EventSubscription(this, function() listeners.remove(listener));
	}

	/**
	 * Routes key, window close and resize, surface ready, lost, and resize, and frame completion events by source.
	 * Returning true from a key handler stops subsequent handlers for that source.
	 */
	public function listenSource(source:Handle, listener:PlatformEvent->Bool):EventSubscription {
		ensureLive();
		if (!source.isValid() || listener == null)
			throw BindingError.invalidArgument("EventPump.listenSource", "A live source and listener are required");
		var id = source.rawValue();
		var known = sourceListeners.get(id);
		if (known == null) {
			known = [];
			sourceListeners.set(id, known);
		}
		// The unsubscribe closure captures the list; a local never assigned again keeps its null check there.
		final routes = known;
		var route = new SourceRoute(listener);
		routes.push(route);
		return new EventSubscription(this, function() {
			route.active = false;
			routes.remove(route);
			if (routes.length == 0)
				sourceListeners.remove(id);
		});
	}

	/** Reports whether this runtime's event pump has been shut down. */
	public function isDisposed():Bool
		return disposed;

	/** Stops the pump after its owning runtime shuts down. */
	@:allow(haxeon.platform.Runtime)
	@:allow(ShowcaseDesktop)
	private function runtimeShutdown():Void {
		disposed = true;
		listeners.resize(0);
		sourceListeners.clear();
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
		var source = switch value {
			case Key(source, _, _, _, _) | WindowClose(source) | WindowResize(source, _,
				_) | SurfaceReady(source) | SurfaceLost(source)
				| SurfaceResize(source, _, _, _, _) | SurfaceFrameComplete(source, _, _): source;
			case _: null;
		};
		var keyEvent = switch value {
			case Key(_, _, _, _, _): true;
			case _: false;
		};
		if (source != null) {
			var routes = sourceListeners.get(source.rawValue());
			if (routes != null) {
				for (route in routes.copy()) {
					if (!route.active || disposed)
						continue;
					try {
						if (route.listener(value) && keyEvent)
							break;
					} catch (error:Dynamic) {
						if (failure == null)
							failure = error;
					}
				}
			}
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
			throw BindingError.disposed("EventPump.ensureLive",
				"NativeKit event pump has been disposed with its runtime");
	}
}


private class SourceRoute {
	public final listener:PlatformEvent->Bool;
	public var active = true;

	public function new(listener:PlatformEvent->Bool) this.listener = listener;
}
