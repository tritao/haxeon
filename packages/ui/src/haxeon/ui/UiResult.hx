package haxeon.ui;

import NativeKitUI.UiStatus;
import haxeon.platform.PlatformError;

/** Exception raised when a NativeKit UI operation returns an error. */
class UiError extends PlatformError {
	/** The native status code. */
	public final status:UiStatus;

	/** An error for `status` in `operation`. */
	public function new(status:UiStatus, operation:String) {
		super("nativekit-ui", status.rawValue, operation, null);
		this.status = status;
	}
}

/** Centralizes raw UI result handling for the high-level graphics API. */
class UiResult {
	/** Throws a `UiError` when `status` reports a failure. */
	public static function check(status:UiStatus, operation:String):Void {
		if (status != UiStatus.Ok)
			throw new UiError(status, operation);
	}
}
