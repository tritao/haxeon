package compiler.formatter;

/** Formatting policy for one boundary between adjacent logical-line tokens. */
typedef Boundary = {
	final spaces:Int;
	final canBreak:Bool;
	final mustBreak:Bool;
	final penalty:Int;
	final continuationIndent:Int;
}
