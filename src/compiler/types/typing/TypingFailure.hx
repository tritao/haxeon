package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.types.TypedAst.TypedFunction;

/**
 * A typing that recovered from failed bodies (`TypingSession.recover`) and fails with one diagnostic per failed body. It carries
 * the bodies that did type, so the editor can index them (`FrontendCompilation`); nothing else reads them, and nothing is generated
 * or cached from them.
 */
class TypingFailure extends CompileError {
	/** The functions typed without error: declared bodies, and the lambdas and specializations they made. */
	public final typed:Array<TypedFunction>;

	/** The modules whose semantic models were built from `typed` (`FrontendCompilation.indexRecoveredTyping`), by name. */
	public final indexedModules:Map<String, Bool> = [];

	public function new(diagnostics:Array<Diagnostic>, typed:Array<TypedFunction>) {
		super(diagnostics[0], diagnostics.slice(1));
		this.typed = typed;
	}
}
