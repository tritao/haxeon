package haxeon.platform;

import haxeon.async.Future;
import haxeon.async.Outcome;
import haxeon.async.Promise;
import haxeon.platform.event.EventPump;
import nativekit.ffi.NativeKit;

/**
	A desktop notification the app showed. `shown` settles once the platform shows it, or with why it could not. The
	user may then activate it, with the action they chose (`onActivated`), or dismiss it (`onDismissed`); either ends
	it, as does `close`, which removes it from the screen.
**/
class Notification {
	/** Whether the platform showed it. */
	public final shown:Future<Result<Void, NativeKitError>>;

	final request:haxe.Int64;
	final events:EventPump;
	final shownPromise = new Promise<Result<Void, NativeKitError>>();
	var activated:Null<String->Void> = null;
	var dismissed:Null<Void->Void> = null;
	var ended = false;

	function new(events:EventPump, request:haxe.Int64) {
		this.events = events;
		this.request = request;
		shown = shownPromise.future;
	}

	/** Shows a notification of `options`, answering through `events`; `Unsupported` where the platform has none. */
	public static function show(events:EventPump, options:NotificationOptions):Result<Notification, NativeKitError> {
		if (events == null || options == null || options.title == null || options.title.length == 0)
			throw BindingError.invalidArgument("Notification.show", "A notification needs an event pump and a title");
		var started = NativeKit.nk_notification_show(options.nativeValue());
		return NativeKitStatus.made(started.status, "Notification.show", NativeKit.nk_last_error(), () -> {
			var notification = new Notification(events, started.out_request);
			events.trackNotification(notification);
			notification;
		});
	}

	/** Calls `handler` with the action the user chose when they activate the notification ("default" for its body). */
	public function onActivated(handler:String->Void):Void
		activated = handler;

	/** Calls `handler` when the notification is dismissed, by the user, the platform or `close`. */
	public function onDismissed(handler:Void->Void):Void
		dismissed = handler;

	/** Removes the notification; `onDismissed` follows. Does nothing once it has ended. */
	public function close():Void {
		if (ended)
			return;
		NativeKitStatus.check(NativeKit.nk_notification_close(request), "Notification.close",
			NativeKit.nk_last_error());
	}

	/** Whether it has ended: activated, dismissed, or failed to show. */
	public function isEnded():Bool
		return ended;

	internal function key():String
		return Std.string(request);

	internal function receive(signal:NotificationSignal):Void
		switch signal {
			case Delivered(_):
				settle(Ok());
			case Activated(_, action):
				settle(Ok());
				end();
				if (activated != null)
					activated(action);
			case Dismissed(_):
				settle(Ok());
				end();
				if (dismissed != null)
					dismissed();
			case Failed(_, error):
				settle(Err(error));
				end();
		}

	/** Ends it unshown, when its runtime goes away first. */
	internal function abandon():Void {
		if (!shown.isComplete())
			shownPromise.resolve(Outcome.Cancelled);
		ended = true;
	}

	function settle(answer:Result<Void, NativeKitError>):Void
		if (!shown.isComplete())
			shownPromise.resolve(Success(answer));

	function end():Void {
		ended = true;
		events.forgetNotification(this);
	}
}
