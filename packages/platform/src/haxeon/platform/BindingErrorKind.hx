package haxeon.platform;

/** Stable managed error categories, separate from backend result codes. */
enum abstract BindingErrorKind(Int) to Int {
	/** An argument was out of range or missing. */
	var InvalidArgument = 1;

	/** The object was not in a state that allows the call. */
	var InvalidState = 2;

	/** The object had been disposed. */
	var Disposed = 3;

	/** Data was malformed. */
	var InvalidData = 4;
}
