package haxe.io;

/** What an input or output fails with, as in Haxe. */
enum Error {
	/** The operation would block (a non-blocking socket has nothing to read or no room to write). */
	Blocked;

	/** An integer is too large for the bytes it is written to. */
	Overflow;

	/** A range is outside the bytes it is read from or written to. */
	OutsideBounds;

	/** Another error, which `e` describes. */
	Custom(e:Dynamic);
}
