package haxe.io;

/** Thrown by an input read past its end, such as `Sys.stdin().readLine()` after the last line. */
class Eof {
	/** The end of an input. */
	public function new() {}

	/** `"Eof"`. */
	public function toString():String
		return "Eof";
}
