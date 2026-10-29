package haxeon.platform;

/** Stable managed error categories, separate from backend result codes. */
enum abstract BindingErrorKind(Int) to Int {
	var InvalidArgument = 1;
	var InvalidState = 2;
	var Disposed = 3;
	var InvalidData = 4;
}
