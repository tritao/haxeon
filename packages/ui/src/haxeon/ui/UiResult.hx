package haxeon.ui;

import NativeKitUI.UiStatus;
import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.PlatformError;

/** Why the UI library could not do what was asked, when that is not the program's mistake. */
enum UiFailure {
	/** It ran out of memory. */
	OutOfMemory;

	/** The graphics backend could not initialize or execute the render. */
	RenderingFailed;

	/** A frame exceeded its stream budget or could not get another page; a later frame may succeed. */
	ResourceLimit;

	/** What went wrong, in a few words. */
	public function describe():String
		return switch this {
			case OutOfMemory: "out of memory";
			case RenderingFailed: "rendering failed";
			case ResourceLimit: "resource limit";
		};
}

/** A `UiFailure` thrown by an operation of the UI library. */
class UiException extends PlatformError {
	/** What failed. */
	public final failure:UiFailure;

	/** `failure`, raised by `operation`; `code` is the UI library's status code. */
	public function new(failure:UiFailure, operation:String, code:Int) {
		super("nativekit-ui", code, operation, failure.describe());
		this.failure = failure;
	}
}

/**
 * The UI library's status codes, told apart: a code that is the program's mistake throws a `BindingError` (a bad
 * argument, a display list that fails validation, a stale handle, a buffer too small), and any other is a `UiFailure`,
 * thrown as a `UiException`. The switch names every code, so a new one fails to build until it is classified.
 */
class UiResult {
	/** Does nothing for `Ok`; otherwise throws the failure `status` is. */
	public static function check(status:UiStatus, operation:String):Void {
		if (status != UiStatus.Ok)
			throw failure(status, operation);
	}

	/** What to throw for the failure `status`. */
	public static function failure(status:UiStatus, operation:String):PlatformError {
		var explanation = 'UI status ${status.rawValue}';
		return switch status {
			case UiStatus.Ok: throw BindingError.invalidState("UiResult.failure", "Ok is not a failure");
			case UiStatus.ErrorInvalidArgument, UiStatus.ErrorBufferTooSmall:
				new BindingError(BindingErrorKind.InvalidArgument, operation, explanation);
			case UiStatus.ErrorInvalidTransaction: new BindingError(BindingErrorKind.InvalidData, operation,
				explanation);
			case UiStatus.ErrorInvalidHandle: new BindingError(BindingErrorKind.Disposed, operation, explanation);
			case UiStatus.ErrorOutOfMemory: new UiException(OutOfMemory, operation, status.rawValue);
			case UiStatus.ErrorRendering: new UiException(RenderingFailed, operation, status.rawValue);
			case UiStatus.ErrorResourceLimit: new UiException(ResourceLimit, operation, status.rawValue);
		};
	}
}
