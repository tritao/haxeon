package haxe.io;

/** Thrown by an input read past its end, such as `Sys.stdin().readLine()` after the last line. */
class Eof {
	public function new() {}

	public function toString():String
		return "Eof";
}
