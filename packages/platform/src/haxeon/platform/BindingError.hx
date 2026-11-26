package haxeon.platform;

import haxeon.platform.PlatformError;

/** Managed API validation or lifecycle failure. Native backend errors keep their own domain. */
class BindingError extends PlatformError {
	/** What kind of misuse it reports. */
	public final kind:BindingErrorKind;

	/** An error of `kind` in `operation`. */
	public function new(kind:BindingErrorKind, operation:String, message:String) {
		super("haxeon-bindings", kind, operation, message);
		this.kind = kind;
	}

	/** An error for a bad argument. */
	public static function invalidArgument(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidArgument, operation, message);

	/** An error for a call at the wrong time. */
	public static function invalidState(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidState, operation, message);

	/** An error for a call on a disposed object. */
	public static function disposed(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.Disposed, operation, message);

	/** An error for malformed data. */
	public static function invalidData(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidData, operation, message);
}
