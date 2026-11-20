package compiler.types;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.types.Type.CompilerType;
import haxe.ds.ObjectMap;

/**
 * The parts of an unannotated function's signature its body gives it, in the function's own and its owner's type parameters: an
 * entry for each argument, null where the argument is annotated, and the result, null where it is annotated. Argument types are as
 * callers see them (`Null<T>` for an optional argument). A warm build keeps them per module (`ModuleState.inferredSignatures`).
 */
typedef InferredSignature = {
	final arguments:Array<Null<CompilerType>>;
	final result:Null<CompilerType>;
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

	/**
	 * The argument types of `fn`, in its own and its owner's type parameters, then substituted, as callers and its function type
	 * see them: an optional argument (`?x:T`, or `x:T = null`) is `Null<T>`, Haxe's rule.
	 */
	function argumentTypes(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType>;

	/** The result type of `fn`, in its own and its owner's type parameters, then substituted. */
	function resultType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType;
}

/**
 * The declared types as the syntax gives them: an annotation. What DeclarationIndex answers before the typer binds its table, and
 * what that table answers for annotated declarations. An unannotated field, result or argument has no declared type: only the
 * table gives it (an argument with a default value and no type has the default's, as the body typer gives it).
 */
class DeclaredTypes implements DeclarationTypes {
	final declarations:DeclarationIndex;

	/**
	 * Annotations resolved with no substitutions, by declaration: the typer reads a member's declared type at every use. Such a
	 * resolution depends only on the index's tables, which never change, and a failed one throws before anything is stored;
	 * the types are immutable, so uses share them, as `DeclarationIndex.resolvedAliases` does.
	 */
	final fieldTypes = new ObjectMap<AstField, CompilerType>();
	final argumentTypesByArgument = new ObjectMap<AstArgument, CompilerType>();
	final resultTypes = new ObjectMap<AstFunction, CompilerType>();

	public function new(declarations:DeclarationIndex)
		this.declarations = declarations;

	public function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType {
		var shared = declarations.resolvesShareable(substitutions);
		var cached = shared ? fieldTypes.get(field) : null;
		if (cached != null)
			return cached;
		var type = declarations.resolve(declarations.declaredFieldType(owner, field), field.span, substitutions);
		if (shared)
			fieldTypes.set(field, type);
		return type;
	}

	public function argumentTypes(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType>
		return [for (argument in fn.arguments) argumentType(argument, substitutions, null)];

	public function resultType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType {
		var shared = declarations.resolvesShareable(substitutions);
		var cached = shared ? resultTypes.get(fn) : null;
		if (cached != null)
			return cached;
		var type = declarations.resolve(fn.result, fn.span, substitutions);
		if (shared)
			resultTypes.set(fn, type);
		return type;
	}

	/**
	 * `argument`'s type as callers see it: its annotation resolved, or, unannotated with a default value, `inferredDefault` (the
	 * value's type, Dynamic when unknown); then `Null<T>` when the argument is optional by Haxe's rule.
	 */
	public function argumentType(argument:AstArgument, substitutions:Null<Map<String, CompilerType>>,
			inferredDefault:Null<CompilerType>):CompilerType {
		if (typedByDefault(argument))
			return optional(argument, inferredDefault == null ? TDynamic : inferredDefault);
		var shared = declarations.resolvesShareable(substitutions);
		var cached = shared ? argumentTypesByArgument.get(argument) : null;
		if (cached != null)
			return cached;
		var type = optional(argument, declarations.resolve(argument.type, argument.span, substitutions));
		if (shared)
			argumentTypesByArgument.set(argument, type);
		return type;
	}

	/** `type` as an argument's callers see it: `Null<T>` when the argument is optional by Haxe's rule. */
	static function optional(argument:AstArgument, type:CompilerType):CompilerType
		return compiler.syntax.AstPredicates.isNullableArgument(argument) && !(switch type {
			case TNullable(_): true;
			default: false;
		}) ? TNullable(type) : type;

	/** Whether `argument` is unannotated with a default value, so its type is the value's. */
	public static function typedByDefault(argument:AstArgument):Bool
		return argument.defaultValue != null && (switch argument.type {
			case InferredType: true;
			default: false;
		});
}
