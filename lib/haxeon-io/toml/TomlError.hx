package toml;

/** A TOML document that is not valid, with where: `line` and `column` count from 1, the column in characters. */
class TomlError extends haxe.Exception {
	/** The line of the error, from 1. */
	public final line:Int;

	/** The column of the error, from 1, in characters. */
	public final column:Int;

	/** What is wrong, without the position. */
	public final reason:String;

	/** The error `reason` at `line` and `column`, whose message gives both. */
	public function new(reason:String, line:Int, column:Int) {
		super('line $line, column $column: $reason');
		this.reason = reason;
		this.line = line;
		this.column = column;
	}
}
