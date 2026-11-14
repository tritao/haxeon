package tools;

import compiler.formatter.TokenPreservation;

/** Expose the compiler's lexer guard to the host formatter's checked file writer. */
@:expose("FormatterTokenGuard")
class FormatterTokenGuard {
	public static function verify(path:String, source:String, formatted:String):Void
		TokenPreservation.verify(path, source, formatted);

	static function main():Void {}
}
