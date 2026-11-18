package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

/**
 * The value of an assignment used as one (`AssignmentValue`: `(a = b)`, `(a += b)`, `++a`), as Haxe gives it: the result of the
 * setter where a property's setter stores it, else the value stored. The store's typing hands the value it stores, already
 * converted to the target's type, to `bind`, which binds it to a local the store then writes; a store through a setter hands
 * the setter's call to `setter`.
 */
class AssignedValue {
	final session:TypingSession;
	final span:SourceSpan;
	var binding:Null<TypedStatement> = null;
	var stored:Null<TypedExpression> = null;
	var setterCall:Null<TypedExpression> = null;

	public function new(session:TypingSession, span:SourceSpan) {
		this.session = session;
		this.span = span;
	}

	/**
	 * Binds `value`, the value the assignment stores, to a local, and returns the local's read for the store to write. `source` is
	 * the type of what was assigned before it was converted to the target's: the value is known not to be null where that is not
	 * nullable, as a read of the target after the store would be (`StatementTyper`'s flow refinement).
	 */
	public function bind(value:TypedExpression, source:CompilerType):TypedExpression {
		if (binding != null)
			throw new InternalError("An assignment stores one value");
		var id = '$' + 'assigned-value:${session.currentContext.assignedValueTemporary++}';
		binding = TVar(id, ValueCopy.bind(session, value, value.type), value.span);
		var local = new TypedExpression(TLocal(id), value.type, value.span),
			known = switch [source, value.type] {
				case [TNull | TNullable(_) | TDynamic, _]: value.type;
				case [_, TNullable(element)]: element;
				default: value.type;
			};
		stored = TypeRelations.equals(known, value.type) ? local : new TypedExpression(TCast(local), known, value.span);
		return local;
	}

	/** `call`, the call of the setter that stores the value, is the assignment's value. */
	public function setter(call:TypedExpression):TypedExpression {
		setterCall = call;
		return call;
	}

	/** The assignment as a value, from `statement`, the store its typing gave. */
	public function value(statement:TypedStatement):TypedExpression {
		var statements:Array<TypedStatement> = binding == null ? [] : [binding];
		if (setterCall != null)
			return new TypedExpression(TBlockExpression(statements, setterCall), setterCall.type, span);
		if (stored == null)
			throw new InternalError("An assignment used as a value bound no value");
		statements.push(statement);
		return new TypedExpression(TBlockExpression(statements, stored), stored.type, span);
	}
}
