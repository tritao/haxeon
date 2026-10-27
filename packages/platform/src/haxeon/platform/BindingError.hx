package haxeon.platform;

import haxeon.platform.PlatformError;

/** Managed API validation or lifecycle failure. Native backend errors keep their own domain. */
class BindingError extends PlatformError {
	public final kind:BindingErrorKind;

	public function new(kind:BindingErrorKind, operation:String, message:String) {
		super("haxeon-bindings", kind, operation, message);
		this.kind = kind;
	}

	public static function invalidArgument(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidArgument, operation, message);

	public static function invalidState(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidState, operation, message);

	public static function disposed(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.Disposed, operation, message);

	public static function invalidData(operation:String, message:String):BindingError
		return new BindingError(BindingErrorKind.InvalidData, operation, message);
}
