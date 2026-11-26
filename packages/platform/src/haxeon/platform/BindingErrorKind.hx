package haxeon.platform;

/** Stable managed error categories, separate from backend result codes. */
enum BindingErrorKind:Int {
	/** An argument was out of range or missing. */
	InvalidArgument = 1;

	/** The object was not in a state that allows the call. */
	InvalidState = 2;

	/** The object had been disposed. */
	Disposed = 3;

	/** Data was malformed. */
	InvalidData = 4;
}
