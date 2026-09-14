package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.InlineConstantEvaluator;
import compiler.types.analysis.Scope;
import compiler.types.typing.TypingSession.ResolvedInlineConstant;

typedef InlineStaticField = {owner:String, type:CompilerType};
typedef InlineStaticFieldLookup = (String, String) -> Null<InlineStaticField>;
typedef InlineInitializerTyper = (AstExpression, String, String, CompilerType, Array<String>) -> TypedExpression;
typedef InlineCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;

/** Resolves inline fields, detects cycles, and memoizes their typed constant values. */
class InlineConstantResolver {
	final session:TypingSession;
	final findStaticField:InlineStaticFieldLookup;
	final typeInitializer:InlineInitializerTyper;
	final coerce:InlineCoerceCallback;

	public function new(session:TypingSession, findStaticField:InlineStaticFieldLookup, typeInitializer:InlineInitializerTyper, coerce:InlineCoerceCallback) {
		this.session = session;
		this.findStaticField = findStaticField;
		this.typeInitializer = typeInitializer;
		this.coerce = coerce;
	}

	public function resolve(owner:String, name:String, span:SourceSpan):Null<ResolvedInlineConstant> {
		var classDecl = session.classDecls.get(owner);
		if (classDecl == null)
			return null;
		var field:Null<AstField> = null;
		for (candidate in classDecl.fields)
			if (candidate.isStatic && candidate.isInline && candidate.name == name) {
				field = candidate;
				break;
			}
		if (field == null || field.initializer == null)
			return null;
		var staticField = findStaticField(owner, name);
		if (staticField == null)
			return null;
		var key = staticField.owner + "." + name,
			cached = session.inlineConstants.get(key);
		if (cached != null)
			return cached;
		if (session.inlineConstantsInProgress.exists(key))
			fail("E1002", 'Cyclic inline constant reference through "$key"', span);
		session.inlineConstantsInProgress.set(key, true);
		var resolved:ResolvedInlineConstant;
		try {
			var initializer = typeInitializer(field.initializer, staticField.owner, name, staticField.type, classDecl.typeParameters),
				literal = InlineConstantEvaluator.evaluate(initializer);
			if (literal == null)
				fail("E1002", 'Inline field "${staticField.owner}.$name" requires a compile-time constant initializer', field.span);
			resolved = {
				initializer: initializer,
				value: coerce(literal, staticField.type, 'inline field "${staticField.owner}.$name"', "E1002")
			};
		} catch (error:Dynamic) {
			session.inlineConstantsInProgress.remove(key);
			throw error;
		}
		session.inlineConstantsInProgress.remove(key);
		session.inlineConstants.set(key, resolved);
		return resolved;
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
