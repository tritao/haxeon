package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.types.DeclarationTypes.InferredSignature;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.LambdaTrailingValue;
import compiler.types.TypedAst.NonExceptionThrow;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.UnboundLocal;

/**
 * A typing that recovered from failed bodies (`TypingSession.recover`) and fails with one diagnostic per failed body. It carries
 * the bodies that did type, so the editor can index them (`FrontendCompilation`), and their lint facts (unbound locals,
 * non-exception throws), which lint reports, and the types the table gave unannotated declarations;
 * nothing is generated or cached from them.
 */
class TypingFailure extends CompileError {
	/** The functions typed without error: declared bodies, and the lambdas and specializations they made. */
	public final typed:Array<TypedFunction>;

	/** The modules whose semantic models were built from `typed` (`FrontendCompilation.indexRecoveredTyping`), by name. */
	public final indexedModules:Map<String, Bool> = [];

	/** The unbound locals of the bodies that typed (`TypedProgram.unboundLocals`); none of a failed body's. */
	public final unboundLocals:Array<UnboundLocal>;

	/** The non-exception throws of the bodies that typed (`TypedProgram.nonExceptionThrows`); none of a failed body's. */
	public final nonExceptionThrows:Array<NonExceptionThrow>;

	/** The lambdas ending in an expression of the bodies that typed (`TypedProgram.lambdaTrailingValues`); none of a failed body's. */
	public final lambdaTrailingValues:Array<LambdaTrailingValue>;

	/**
	 * The types the table gave the unannotated fields that typed, by key (`DeclarationTypeTable.knownFieldTypes`), so the editor keeps
	 * them next to the error.
	 */
	public final inferredFieldTypes:Map<String, CompilerType>;

	/** The signatures the table gave the unannotated functions that typed, by key (`DeclarationTypeTable.typedSignatures`). */
	public final inferredSignatures:Map<String, InferredSignature>;

	public function new(diagnostics:Array<Diagnostic>, typed:Array<TypedFunction>, unboundLocals:Array<UnboundLocal>,
			nonExceptionThrows:Array<NonExceptionThrow>, lambdaTrailingValues:Array<LambdaTrailingValue>,
			inferredFieldTypes:Map<String, CompilerType>,
			inferredSignatures:Map<String, InferredSignature>) {
		super(diagnostics[0], diagnostics.slice(1));
		this.typed = typed;
		this.inferredFieldTypes = inferredFieldTypes;
		this.inferredSignatures = inferredSignatures;
		this.unboundLocals = unboundLocals;
		this.nonExceptionThrows = nonExceptionThrows;
		this.lambdaTrailingValues = lambdaTrailingValues;
	}
}
