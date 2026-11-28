package haxeon.platform;

import haxeon.platform.NativeKitError;

/** What NativeKit reports about a notification, which the event pump hands to it alone. */
internal enum NotificationSignal {
	Delivered(request:haxe.Int64);
	Activated(request:haxe.Int64, action:String);
	Dismissed(request:haxe.Int64);
	Failed(request:haxe.Int64, error:NativeKitError);
}
