package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.TypeRelations;
import compiler.types.analysis.Scope;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

typedef StatementExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef StatementCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ExpectedInitializerCallback = (String, AstExpression, Array<AstStatement>, Int) -> Null<CompilerType>;
typedef BindCellCallback = (String, SourceSpan, Scope, CompilerType) -> Void;

/** Types straight-line statements whose behavior is local to one body context. */
class StatementTyper {
	final session:TypingSession;
	final typeExpression:StatementExpressionCallback;
	final coerce:StatementCoerceCallback;
	final expectedInitializerType:ExpectedInitializerCallback;
	final bindCell:BindCellCallback;

	public function new(session:TypingSession, typeExpression:StatementExpressionCallback, coerce:StatementCoerceCallback,
			expectedInitializerType:ExpectedInitializerCallback, bindCell:BindCellCallback) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
		this.expectedInitializerType = expectedInitializerType;
		this.bindCell = bindCell;
	}

	/** Returns null for statements handled by the compound-statement dispatcher. */
	public function typeSimpleStatement(statement:AstStatement, scope:Scope, result:Null<CompilerType>, statements:Array<AstStatement>,
			statementIndex:Int):Null<Array<TypedStatement>> {
		var context = session.currentContext;
		return switch statement {
			case ErrorStatement(_): [];
			case UninitializedDeclaration(name, declared, span):
				var declaredType = session.declarations.resolve(declared, null, context.typeSubstitutions),
					declarationKey = LexicalStorageAnalysis.key(name, span);
				if (context.storage.hasCandidate(declarationKey) && context.storage.candidateKind(declarationKey) == MutableCapture)
					fail("E1023", 'Captured local "$name" must be initialized at its declaration', span);
				scope.define(name, declaredType, span, false);
				bindCell(name, span, scope, declaredType);
				[TDeclare(scope.requireId(name), declaredType, span)];
			case VarDeclaration(name, declared, initializer, span):
				var declaredType:Null<CompilerType> = declared == null ? expectedInitializerType(name, initializer, statements,
					statementIndex + 1) : session.declarations.resolve(declared, null, context.typeSubstitutions);
				var predeclared = false;
				if (declaredType != null)
					switch initializer {
						case Lambda(_, _, _):
							scope.define(name, declaredType, span);
							predeclared = true;
						default:
					}
				var value = typeExpression(initializer, scope, declaredType, false);
				if (declaredType != null)
					value = coerce(value, declaredType, 'local "$name"', "E1002");
				else if (TypeRelations.equals(value.type, TNull))
					fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
				if (!predeclared)
					scope.define(name, value.type, span);
				bindCell(name, span, scope, value.type);
				[TVar(scope.requireId(name), value, span)];
			case Return(expression, span):
				var expected = result == null ? context.inferredResult : result;
				var value = typeExpression(expression, scope, expected, false),
					output:Array<TypedStatement> = [];
				if (expected != null && expected == TVoid && context.contextualVoidLambda) {
					output.push(TExpression(value, span));
					output.push(TReturnVoid(span));
				} else {
					if (expected == null)
						context.inferredResult = value.type;
					else
						value = coerce(value, expected, "return", "E1003");
					output.push(TReturn(value, span));
				}
				output;
			case ReturnVoid(span):
				var expected = result == null ? context.inferredResult : result;
				if (expected == null)
					context.inferredResult = TVoid;
				else if (expected != TVoid)
					fail("E1003", "Return type mismatch", span);
				[TReturnVoid(span)];
			case Throw(expression, span):
				var value = typeExpression(expression, scope, null, false);
				if (TypeRelations.equals(value.type, TVoid))
					fail("E1021", "Cannot throw a Void value", span);
				if (TypeRelations.equals(value.type, TNull))
					fail("E1021", "Cannot throw null", span);
				[TThrow(value, span)];
			case Break(span):
				if (context.loopDepth == 0)
					fail("E1017", "break is only valid inside a loop", span);
				if (!context.loopEarlyExits[context.loopDepth - 1])
					fail("E1017", "break in do-while is not supported by the current CFG backend", span);
				[TBreak(span)];
			case Continue(span):
				if (context.loopDepth == 0)
					fail("E1017", "continue is only valid inside a loop", span);
				if (!context.loopEarlyExits[context.loopDepth - 1])
					fail("E1017", "continue in do-while is not supported by the current CFG backend", span);
				[TContinue(span)];
			case Expression(expression, span):
				[TExpression(typeExpression(expression, scope, null, false), span)];
			default: null;
		};
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
