package toml;

/** A TOML document that is not valid, with where: `line` and `column` count from 1, the column in characters. */
class TomlError extends haxe.Exception {
	public final line:Int;
	public final column:Int;

	/** What is wrong, without the position. */
	public final reason:String;

	public function new(reason:String, line:Int, column:Int) {
		super('line $line, column $column: $reason');
		this.reason = reason;
		this.line = line;
		this.column = column;
	}
}
