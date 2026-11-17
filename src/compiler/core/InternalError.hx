package compiler.core;

import compiler.core.Source.SourceSpan;

/**
 * A failure that is not a located compile error (`CompileError`): a broken compiler invariant, a construct a later stage does not
 * support, a malformed input or state file, a command-line usage error. Haxeon throws only haxe.Exception subclasses (`haxeon lint
 * --only throw-non-exception`), so a catch of haxe.Exception never wraps one. The message is the whole text: `toString` returns it,
 * so an error printed with `Std.string`, or one nobody catches, reads as the message alone. `span` is the source it concerns, when
 * the thrower knows it.
 */
class InternalError extends haxe.Exception {
	public final span:Null<SourceSpan>;

	public function new(message:String, ?span:SourceSpan, ?previous:haxe.Exception) {
		super(message, previous);
		this.span = span;
	}
}
