package haxeon.platform;

import nativekit.ffi.NativeKitTypes.NotificationFlags;
import nativekit.ffi.NativeKitTypes.NotificationOptions as NativeNotificationOptions;

/** What a desktop notification shows (`Notification.show`). */
class NotificationOptions {
	/** The title, which a notification must have. */
	public final title:String;

	/** The text under the title, or null for none. */
	public var body:Null<String> = null;

	/** A platform icon name or an absolute file path, or null for the app's. */
	public var icon:Null<String> = null;

	/** How long it shows, in seconds; 0 leaves it to the platform. */
	public var timeoutSeconds:Float = 0;

	/** Whether it shows without a sound or vibration, where the platform lets it. */
	public var silent:Bool = false;

	/** A notification titled `title`. */
	public function new(title:String)
		this.title = title;

	internal function nativeValue():NativeNotificationOptions {
		var options = new NativeNotificationOptions();
		options.set_title(title);
		options.set_body(body);
		options.set_icon(icon);
		options.set_timeout_ms(Std.int(timeoutSeconds * 1000));
		options.set_flags(silent ? NotificationFlags.Silent : NotificationFlags.empty());
		return options;
	}
}
