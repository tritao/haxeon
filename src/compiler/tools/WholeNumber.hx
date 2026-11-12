package compiler.tools;

/** Prints a counter kept as a Float without squeezing it through an Int: a compile allocates more than 2^31 bytes. */
class WholeNumber {
	public static function text(value:Float):String {
		var whole = Math.ffloor(value + 0.5);
		var text = Std.string(whole);
		return StringTools.endsWith(text, ".0") ? text.substr(0, text.length - 2) : text;
	}
}
