package compiler.types;

import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.types.Type.CompilerType;

/** A function's argument and result types, resolved. */
typedef ResolvedSignature = {
	final arguments:Array<CompilerType>;
	final result:CompilerType;
}

/**
 * The types of declarations, resolved: the one query every reader of a field's type or a function's signature goes through
 * (docs/design/LAZY_DECLARATION_TYPING.md). An annotated declaration resolves its annotation; an unannotated one gets the type
 * its initializer or body gives it. It lives below the typer so that DeclarationIndex, TypeRelations, StructProperties and
 * IterationProtocol can ask it; the typer's implementation is DeclarationTypeTable.
 */
interface DeclarationTypes {
	/** The type of `owner`'s field `field`, in its class's own type parameters, then substituted. */
	function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType;

	/** The argument and result types of `fn`, in its own and its owner's type parameters, then substituted. */
	function signature(fn:AstFunction, ?substitutions:Map<String, CompilerType>):ResolvedSignature;
}

/**
 * The declared types as the syntax gives them: an annotation, or what FieldInference and SignatureInference read from an
 * initializer or body. What DeclarationIndex answers before the typer binds its table, and what that table answers for
 * annotated declarations.
 */
class DeclaredTypes implements DeclarationTypes {
	final declarations:DeclarationIndex;

	public function new(declarations:DeclarationIndex)
		this.declarations = declarations;

	public function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType
		return declarations.resolve(declarations.declaredFieldType(owner, field), field.span, substitutions);

	public function signature(fn:AstFunction, ?substitutions:Map<String, CompilerType>):ResolvedSignature
		return {
			arguments: [for (argument in fn.arguments) declarations.resolve(argument.type, argument.span,
				substitutions)],
			result: declarations.resolve(fn.result, fn.span, substitutions)
		};
}
