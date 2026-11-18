package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Source.SourceSpan;

/**
 * A method call whose receiver has no member of that name (`Unknown String method "trim"`). The call (`CallResolver.typeMethodCall`)
 * then tries the static extensions (`StaticExtensions`), as Haxe tries them only once the value's own members have none; when no
 * extension applies either, the error stands as it is. `span` is the call's, which tells the call that failed apart from a call
 * among its arguments.
 */
class MissingMember extends CompileError {
	public final span:SourceSpan;

	public function new(code:String, message:String, span:SourceSpan) {
		super(new Diagnostic(code, message, span));
		this.span = span;
	}
}
